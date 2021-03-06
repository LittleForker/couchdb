% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_replication_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("couch_db.hrl").
-include("couch_replicator.hrl").
-include("couch_js_functions.hrl").

-define(DOC_TO_REP, couch_rep_doc_id_to_rep_id).
-define(REP_TO_STATE, couch_rep_id_to_rep_state).
-define(INITIAL_WAIT, 5).

-record(rep_state, {
    rep,
    starting,
    retries_left,
    max_retries,
    last_error
}).

-import(couch_replicator_utils, [
    parse_rep_doc/2
]).
-import(couch_util, [
    get_value/2,
    get_value/3,
    to_binary/1
]).

-record(state, {
    changes_feed_loop = nil,
    db_notifier = nil,
    rep_notifier = nil,
    rep_db_name = nil,
    rep_start_pids = [],
    max_retries
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
    process_flag(trap_exit, true),
    ?DOC_TO_REP = ets:new(?DOC_TO_REP, [named_table, set, protected]),
    ?REP_TO_STATE = ets:new(?REP_TO_STATE, [named_table, set, protected]),
    Server = self(),
    ok = couch_config:register(
        fun("replicator", "db", NewName) ->
            ok = gen_server:cast(Server, {rep_db_changed, ?l2b(NewName)});
        ("replicator", "max_replication_retry_count", NewMaxRetries1) ->
            NewMaxRetries = list_to_integer(NewMaxRetries1),
            ok = gen_server:cast(Server, {set_max_retries, NewMaxRetries})
        end
    ),
    {Loop, RepDbName} = changes_feed_loop(),
    {ok, #state{
        changes_feed_loop = Loop,
        rep_db_name = RepDbName,
        db_notifier = db_update_notifier(),
        rep_notifier = rep_notifier(),
        max_retries = list_to_integer(
            couch_config:get("replicator", "max_replication_retry_count", "10"))
    }}.


handle_call({rep_db_update, Change}, _From, State) ->
    {reply, ok, process_update(State, Change)};

handle_call({rep_started, {BaseId, _Ext} = RepId}, _From, State) ->
    case rep_state(RepId) of
    nil ->
        ok;
    #rep_state{rep = #rep{doc_id = DocId}} = RepState ->
        true = ets:insert(
            ?REP_TO_STATE, {RepId, RepState#rep_state{starting = false}}),
        update_rep_doc(DocId, [
            {<<"_replication_state">>, <<"triggered">>},
            {<<"_replication_id">>, ?l2b(BaseId)}]),
        ?LOG_INFO("Document `~s` triggered replication `~s`",
            [DocId, pp_rep_id(RepId)])
    end,
    {reply, ok, State};

handle_call({rep_complete, RepId}, _From, State) ->
    case rep_state(RepId) of
    nil ->
        ok;
    #rep_state{rep = #rep{doc_id = DocId}} ->
        update_rep_doc(DocId, [{<<"_replication_state">>, <<"completed">>}])
    end,
    {reply, ok, State};

handle_call({rep_error, RepId, Error}, _From, State) ->
    case rep_state(RepId) of
    nil ->
        {reply, ok, State};
    #rep_state{rep = #rep{doc_id = DocId}} = RepState ->
        NewRepState = RepState#rep_state{last_error = Error},
        true = ets:insert(?REP_TO_STATE, {RepId, NewRepState}),
        % TODO: maybe add error reason to replication document
        update_rep_doc(DocId, [{<<"_replication_state">>, <<"error">>}]),
        {reply, ok, State}
    end;

handle_call(Msg, From, State) ->
    ?LOG_ERROR("Replication manager received unexpected call ~p from ~p",
        [Msg, From]),
    {stop, {error, {unexpected_call, Msg}}, State}.


handle_cast({rep_db_changed, NewName}, #state{rep_db_name = NewName} = State) ->
    {noreply, State};

handle_cast({rep_db_changed, _NewName}, State) ->
    {noreply, restart(State)};

handle_cast({rep_db_created, NewName}, #state{rep_db_name = NewName} = State) ->
    {noreply, State};

handle_cast({rep_db_created, _NewName}, State) ->
    {noreply, restart(State)};

handle_cast({set_max_retries, MaxRetries}, State) ->
    {noreply, State#state{max_retries = MaxRetries}};

handle_cast(Msg, State) ->
    ?LOG_ERROR("Replication manager received unexpected cast ~p", [Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.


handle_info({'EXIT', From, normal}, #state{changes_feed_loop = From} = State) ->
    % replicator DB deleted
    {noreply, State#state{changes_feed_loop = nil, rep_db_name = nil}};

handle_info({'EXIT', From, Reason}, #state{db_notifier = From} = State) ->
    ?LOG_ERROR("Database update notifier died. Reason: ~p", [Reason]),
    {stop, {db_update_notifier_died, Reason}, State};

handle_info({'EXIT', From, Reason}, #state{rep_notifier = From} = State) ->
    ?LOG_ERROR("Replication notifier died. Reason: ~p", [Reason]),
    {stop, {rep_notifier_died, Reason}, State};

handle_info({'EXIT', From, normal}, #state{rep_start_pids = Pids} = State) ->
    % one of the replication start processes terminated successfully
    {noreply, State#state{rep_start_pids = Pids -- [From]}};

handle_info(Msg, State) ->
    ?LOG_ERROR("Replication manager received unexpected message ~p", [Msg]),
    {stop, {unexpected_msg, Msg}, State}.


terminate(_Reason, State) ->
    #state{
        rep_start_pids = StartPids,
        changes_feed_loop = Loop,
        db_notifier = DbNotifier,
        rep_notifier = RepNotifier
    } = State,
    stop_all_replications(),
    lists:foreach(
        fun(Pid) ->
            catch unlink(Pid),
            catch exit(Pid, stop)
        end,
        [Loop | StartPids]),
    true = ets:delete(?REP_TO_STATE),
    true = ets:delete(?DOC_TO_REP),
    couch_replication_notifier:stop(RepNotifier),
    couch_db_update_notifier:stop(DbNotifier).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


changes_feed_loop() ->
    {ok, RepDb} = ensure_rep_db_exists(),
    Server = self(),
    Pid = spawn_link(
        fun() ->
            ChangesFeedFun = couch_changes:handle_changes(
                #changes_args{
                    include_docs = true,
                    feed = "continuous",
                    timeout = infinity,
                    db_open_options = [sys_db]
                },
                {json_req, null},
                RepDb
            ),
            ChangesFeedFun(
                fun({change, Change, _}, _) ->
                    case has_valid_rep_id(Change) of
                    true ->
                        ok = gen_server:call(
                            Server, {rep_db_update, Change}, infinity);
                    false ->
                        ok
                    end;
                (_, _) ->
                    ok
                end
            )
        end
    ),
    couch_db:close(RepDb),
    {Pid, couch_db:name(RepDb)}.


has_valid_rep_id({Change}) ->
    has_valid_rep_id(get_value(<<"id">>, Change));
has_valid_rep_id(<<?DESIGN_DOC_PREFIX, _Rest/binary>>) ->
    false;
has_valid_rep_id(_Else) ->
    true.


db_update_notifier() ->
    Server = self(),
    {ok, Notifier} = couch_db_update_notifier:start_link(
        fun({created, DbName}) ->
            case ?l2b(couch_config:get("replicator", "db", "_replicator")) of
            DbName ->
                ok = gen_server:cast(Server, {rep_db_created, DbName});
            _ ->
                ok
            end;
        (_) ->
            % no need to handle the 'deleted' event - the changes feed loop
            % dies when the database is deleted
            ok
        end
    ),
    Notifier.


rep_notifier() ->
    Server = self(),
    {ok, Notifier} = couch_replication_notifier:start_link(
        fun({finished, RepId, _CheckPointHistory}) ->
            case rep_state(RepId) of
            nil ->
                ok;
            #rep_state{} ->
                % TODO: maybe add replication stats to the doc
                ok = gen_server:call(Server, {rep_complete, RepId}, infinity)
            end;
        ({error, RepId, Error}) ->
            case rep_state(RepId) of
            nil ->
                ok;
            #rep_state{} ->
                ok = gen_server:call(
                    Server, {rep_error, RepId, Error}, infinity)
            end;
        (_) ->
            ok
        end),
    Notifier.


restart(#state{changes_feed_loop = Loop, rep_start_pids = StartPids} = State) ->
    stop_all_replications(),
    lists:foreach(
        fun(Pid) ->
            catch unlink(Pid),
            catch exit(Pid, rep_db_changed)
        end,
        [Loop | StartPids]),
    {NewLoop, NewRepDbName} = changes_feed_loop(),
    State#state{
        changes_feed_loop = NewLoop,
        rep_db_name = NewRepDbName,
        rep_start_pids = []
    }.


process_update(State, {Change}) ->
    {RepProps} = JsonRepDoc = get_value(doc, Change),
    DocId = get_value(<<"_id">>, RepProps),
    case get_value(<<"deleted">>, Change, false) of
    true ->
        rep_doc_deleted(DocId),
        State;
    false ->
        case get_value(<<"_replication_state">>, RepProps) of
        undefined ->
            maybe_start_replication(State, DocId, JsonRepDoc);
        <<"triggered">> ->
            maybe_start_replication(State, DocId, JsonRepDoc);
        <<"completed">> ->
            replication_complete(DocId),
            State;
        <<"error">> ->
            replication_error(State, DocId)
        end
    end.


rep_user_ctx({RepDoc}) ->
    case get_value(<<"user_ctx">>, RepDoc) of
    undefined ->
        #user_ctx{roles = [<<"_admin">>]};
    {UserCtx} ->
        #user_ctx{
            name = get_value(<<"name">>, UserCtx, null),
            roles = get_value(<<"roles">>, UserCtx, [])
        }
    end.


maybe_start_replication(State, DocId, RepDoc) ->
    {ok, #rep{id = {BaseId, _} = RepId} = Rep} = parse_rep_doc(
        RepDoc, rep_user_ctx(RepDoc)),
    case rep_state(RepId) of
    nil ->
        RepState = #rep_state{
            rep = Rep,
            starting = true,
            retries_left = State#state.max_retries,
            max_retries = State#state.max_retries
        },
        true = ets:insert(?REP_TO_STATE, {RepId, RepState}),
        true = ets:insert(?DOC_TO_REP, {DocId, RepId}),
        ?LOG_INFO("Attempting to start replication `~s` (document `~s`).",
            [pp_rep_id(RepId), DocId]),
        Server = self(),
        Pid = spawn_link(fun() -> start_replication(Server, Rep, 0) end),
        State#state{rep_start_pids = [Pid | State#state.rep_start_pids]};
    #rep_state{rep = #rep{doc_id = DocId}} ->
        State;
    #rep_state{starting = false, rep = #rep{doc_id = OtherDocId}} ->
        ?LOG_INFO("The replication specified by the document `~s` was already"
            " triggered by the document `~s`", [DocId, OtherDocId]),
        maybe_tag_rep_doc(DocId, RepDoc, ?l2b(BaseId)),
        State;
    #rep_state{starting = true, rep = #rep{doc_id = OtherDocId}} ->
        ?LOG_INFO("The replication specified by the document `~s` is already"
            " being triggered by the document `~s`", [DocId, OtherDocId]),
        maybe_tag_rep_doc(DocId, RepDoc, ?l2b(BaseId)),
        State
    end.


maybe_tag_rep_doc(DocId, {RepProps}, RepId) ->
    case get_value(<<"_replication_id">>, RepProps) of
    RepId ->
        ok;
    _ ->
        update_rep_doc(DocId, [{<<"_replication_id">>, RepId}])
    end.


start_replication(Server, #rep{id = RepId} = Rep, Wait) ->
    ok = timer:sleep(Wait * 1000),
    case (catch couch_replicator:async_replicate(Rep)) of
    {ok, _} ->
        ok = gen_server:call(Server, {rep_started, RepId}, infinity);
    Error ->
        ok = gen_server:call(Server, {rep_error, RepId, Error}, infinity)
    end.


replication_complete(DocId) ->
    case ets:lookup(?DOC_TO_REP, DocId) of
    [{DocId, RepId}] ->
        couch_replicator:cancel_replication(RepId),
        true = ets:delete(?REP_TO_STATE, RepId),
        true = ets:delete(?DOC_TO_REP, DocId),
        ?LOG_INFO("Replication `~s` finished (triggered by document `~s`)",
            [pp_rep_id(RepId), DocId]);
    _ ->
        ok
    end.


rep_doc_deleted(DocId) ->
    case ets:lookup(?DOC_TO_REP, DocId) of
    [{DocId, RepId}] ->
        couch_replicator:cancel_replication(RepId),
        true = ets:delete(?REP_TO_STATE, RepId),
        true = ets:delete(?DOC_TO_REP, DocId),
        ?LOG_INFO("Stopped replication `~s` because replication document `~s`"
            " was deleted", [pp_rep_id(RepId), DocId]);
    [] ->
        ok
    end.


replication_error(State, DocId) ->
    case ets:lookup(?DOC_TO_REP, DocId) of
    [{DocId, RepId}] ->
        maybe_retry_replication(rep_state(RepId), State);
    _ ->
        State
    end.

maybe_retry_replication(#rep_state{retries_left = 0} = RepState, State) ->
    #rep_state{
        rep = #rep{id = RepId, doc_id = DocId},
        max_retries = MaxRetries,
        last_error = Error
    } = RepState,
    couch_replicator:cancel_replication(RepId),
    true = ets:delete(?REP_TO_STATE, RepId),
    true = ets:delete(?DOC_TO_REP, DocId),
    ?LOG_ERROR("Error in replication `~s` (triggered by document `~s`): ~s"
        "~nReached maximum retry attempts (~p).",
        [pp_rep_id(RepId), DocId, to_binary(error_reason(Error)), MaxRetries]),
    State;

maybe_retry_replication(RepState, State) ->
    #rep_state{
        rep = #rep{id = RepId, doc_id = DocId} = Rep,
        retries_left = RetriesLeft,
        last_error = Error
    } = RepState,
    NewRepState = RepState#rep_state{retries_left = RetriesLeft - 1},
    true = ets:insert(?REP_TO_STATE, {RepId, NewRepState}),
    Wait = wait_period(NewRepState),
    ?LOG_ERROR("Error in replication `~s` (triggered by document `~s`): ~s"
        "~nRestarting replication in ~p seconds.",
        [pp_rep_id(RepId), DocId, to_binary(error_reason(Error)), Wait]),
    Server = self(),
    Pid = spawn_link(fun() -> start_replication(Server, Rep, Wait) end),
    State#state{rep_start_pids = [Pid | State#state.rep_start_pids]}.


stop_all_replications() ->
    ?LOG_INFO("Stopping all ongoing replications because the replicator"
        " database was deleted or changed", []),
    ets:foldl(
        fun({_, RepId}, _) ->
            couch_replicator:cancel_replication(RepId)
        end,
        ok, ?DOC_TO_REP),
    true = ets:delete_all_objects(?REP_TO_STATE),
    true = ets:delete_all_objects(?DOC_TO_REP).


update_rep_doc(RepDocId, KVs) ->
    {ok, RepDb} = ensure_rep_db_exists(),
    try
        case couch_db:open_doc(RepDb, RepDocId, []) of
        {ok, LatestRepDoc} ->
            update_rep_doc(RepDb, LatestRepDoc, KVs);
        _ ->
            ok
        end
    catch throw:conflict ->
        % Shouldn't happen, as by default only the role _replicator can
        % update replication documents.
        ?LOG_ERROR("Conflict error when updating replication document `~s`."
            " Retrying.", [RepDocId]),
        ok = timer:sleep(5),
        update_rep_doc(RepDocId, KVs)
    after
        couch_db:close(RepDb)
    end.

update_rep_doc(RepDb, #doc{body = {RepDocBody}} = RepDoc, KVs) ->
    NewRepDocBody = lists:foldl(
        fun({<<"_replication_state">> = K, _V} = KV, Body) ->
                Body1 = lists:keystore(K, 1, Body, KV),
                {Mega, Secs, _} = erlang:now(),
                UnixTime = Mega * 1000000 + Secs,
                lists:keystore(
                    <<"_replication_state_time">>, 1, Body1,
                    {<<"_replication_state_time">>, UnixTime});
            ({K, _V} = KV, Body) ->
                lists:keystore(K, 1, Body, KV)
        end,
        RepDocBody, KVs),
    % Might not succeed - when the replication doc is deleted right
    % before this update (not an error, ignore).
    couch_db:update_doc(RepDb, RepDoc#doc{body = {NewRepDocBody}}, []).


ensure_rep_db_exists() ->
    DbName = ?l2b(couch_config:get("replicator", "db", "_replicator")),
    UserCtx = #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]},
    case couch_db:open_int(DbName, [sys_db, {user_ctx, UserCtx}]) of
    {ok, Db} ->
        Db;
    _Error ->
        {ok, Db} = couch_db:create(DbName, [sys_db, {user_ctx, UserCtx}])
    end,
    ensure_rep_ddoc_exists(Db, <<"_design/_replicator">>),
    {ok, Db}.


ensure_rep_ddoc_exists(RepDb, DDocID) ->
    case couch_db:open_doc(RepDb, DDocID, []) of
    {ok, _Doc} ->
        ok;
    _ ->
        DDoc = couch_doc:from_json_obj({[
            {<<"_id">>, DDocID},
            {<<"language">>, <<"javascript">>},
            {<<"validate_doc_update">>, ?REP_DB_DOC_VALIDATE_FUN}
        ]}),
        {ok, _Rev} = couch_db:update_doc(RepDb, DDoc, [])
     end.


% pretty-print replication id
pp_rep_id(#rep{id = RepId}) ->
    pp_rep_id(RepId);
pp_rep_id({Base, Extension}) ->
    Base ++ Extension.


rep_state(RepId) ->
    case ets:lookup(?REP_TO_STATE, RepId) of
    [{RepId, RepState}] ->
        RepState;
    [] ->
        nil
    end.


error_reason({error, Reason}) ->
    Reason;
error_reason(Reason) ->
    Reason.


wait_period(#rep_state{max_retries = Max, retries_left = Left}) ->
    wait_period(Max - Left, ?INITIAL_WAIT).

wait_period(1, T) ->
    T;
wait_period(N, T) when N > 1 ->
    wait_period(N - 1, 2 * T).
