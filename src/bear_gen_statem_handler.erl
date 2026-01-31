%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_handler).

-behaviour(gen_statem).

-define(HANDOFF_TIMEOUT, 60000).
-define(WAIT_FOR_LATE_MSG_TIMEOUT, 3000).
-define(BUCKET, application:get_env(bear, statem_bucket, <<"bear">>)).

%% API
-export([start_link/3, handoff/1, call/3]).

%% gen_statem callbacks
-export([init/1, handle_event/4, terminate/3, callback_mode/0]).

-record(state, {
  id :: binary(),
  module :: module(),
  stored :: rico:obj() | undefined,
  cb_data :: term()
}).

-type state() :: #state{}.

-record(store_state, {
  cb_data :: term(),
  state_name :: term()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec handoff(pid() | term()) -> ok.
handoff(Id) ->
  call(Id, {?MODULE, handoff}, ?HANDOFF_TIMEOUT).

-spec call(pid() | term(), term(), pos_integer() | infinity) -> term().
call(Server, Command, Timeout) when is_pid(Server) ->
  gen_statem:call(Server, Command, Timeout);
call(Id, Command, Timeout) ->
  gen_statem:call({via, pes, Id}, Command, Timeout).

%% @doc Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
start_link(Id, Module, Args) ->
  gen_statem:start_link(?MODULE, [Id, Module, Args], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%% @private
%% @doc Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
init(InitArgs) ->
  init(InitArgs, 3).

init([Id, Module, Args] = InitArgs, MaxRetry) ->
  case pes:register(Id, self()) of
    registered ->
      case rico:fetch(get_bucket(Module), state_key(Module, Id)) of
        {ok, Obj} ->
          logger:debug("For ~p (~p) state found in backend", [Id, Module]),
          #store_state{cb_data = CBData, state_name = StateName} = decode_stored_state(rico:value(Obj)),
          Data = #state{id = Id, stored = Obj, module = Module, cb_data = CBData},
          %erlang:process_flag(trap_exit, true),
          logger:info("~p (~p) started from stored state", [Id, Module]),
          bear_metrics:increase([statem, active]),
          bear_metrics:count([statem, started]),
          {ok, StateName, Data, [{next_event, internal, {?MODULE, state_initialized}}]};
        not_found ->
          case apply(Module, init, [Args]) of
            {ok, StateName, Data, Actions} ->
              State = #state{id = Id, module = Module, cb_data = Data},
              {ok, NewActions, NewState} = process_actions(Actions, StateName, State),
              logger:info("~p (~p) started from initialzed state", [Id, Module]),
              bear_metrics:increase([statem, active]),
              bear_metrics:count([statem, started]),
              {ok, StateName, NewState, NewActions};
            {ok, StateName, Data} ->
              State = #state{id = Id, module = Module, cb_data = Data},
              logger:info("~p (~p) started from initialzed state", [Id, Module]),
              bear_metrics:increase([statem, active]),
              bear_metrics:count([statem, started]),
              {ok, StateName, State}
          end;
        {error, Error} ->
          logger:error("~p (~p) failed to fetch state because ~p", [Id, Module, Error]),
          {error, {failed_to_fetch_state, Error}}
      end;
    {error, {already_registered, Pid}} ->
      case catch gen_statem:call(Pid, {?MODULE, {ready_to_receive, self()}}, ?HANDOFF_TIMEOUT) of
        ok ->
          logger:info("~p (~p) started in handoff mode", [Id, Module]),
          {ok, {?MODULE, wait_for_handoff}, undefined};
        {error, not_in_handoff} ->
          % process not in handoff mode so the handoff process has not started return with error already started;
          {error, {already_started, Pid}};
        {'EXIT', {noproc, _}} when MaxRetry >= 0 ->
          % it seems that in the mean time the handoff has been done.
          timer:sleep(100),
          init(InitArgs, MaxRetry - 1);
        {'EXIT', {{nodedown, _}, _}} when MaxRetry >= 0 ->
          % it seems that then original process went down
          timer:sleep(100),
          init(InitArgs, MaxRetry - 1);
        Error ->
          logger:warning("~p (~p) started in handoff mode, but encountered an error ~p", [Id, Module, Error]),
          ignore
      end;
    {error, {could_not_register, Reason}} when MaxRetry >= 0 ->
      logger:warning("could not lookup ~p ~p, wait and retry", [Id, Reason]),
      timer:sleep(100),
      init(InitArgs, MaxRetry - 1);
    {error, timeout} when MaxRetry >= 0 ->
      logger:warning("could not lookup ~p timeout, wait and retry", [Id]),
      timer:sleep(100),
      init(InitArgs, MaxRetry - 1);
    Else ->
      {error, {lookup_error, Else}}
  end.

%% @private
%% @doc This function is called by a gen_statem when it needs to find out
%% the callback mode of the callback module.
-spec callback_mode() -> [handle_event_function | state_enter].
callback_mode() ->
  [handle_event_function, state_enter].

%% @private
%% @doc If callback_mode is handle_event_function, then whenever a
%% gen_statem receives an event from call/2, cast/2, or as a normal
%% process message, this function is called.
%handle_event(enter, _, _, _State) ->
%  keep_state_and_data;

handle_event({call, From}, {?MODULE, handoff}, StateName,  #state{} = State) ->
  {next_state, {?MODULE, {prepare_handoff, StateName}}, State, [{reply, From, ok}]};

handle_event(enter, _PrevState, {?MODULE, {prepare_handoff, _StateName}}, State) ->
  {keep_state, State, [{state_timeout, ?HANDOFF_TIMEOUT, stop}]};
handle_event({call, From}, {?MODULE, {ready_to_receive, NewPid}}, {?MODULE, {prepare_handoff, StateName}}, #state{} = State) ->
  gen_statem:reply(From, ok),
  {next_state, {?MODULE, {handoff, NewPid, StateName}}, State};
handle_event({call, From}, {?MODULE, {ready_to_receive, _Pid}}, _, #state{} = _State) ->
  gen_statem:reply(From, {error, not_in_handoff}),
  keep_state_and_data;
handle_event(state_timeout, stop, {?MODULE, {prepare_handoff, StateName}}, #state{} = State) ->
  logger:warning("~p (~p) prepare handoff timeout", [State#state.id, State#state.module]),
  {next_state, StateName, State};
handle_event(EventType, _EventContext, {?MODULE, {prepare_handoff, _StateName}}, _State) when EventType =/= enter ->
  % Postpone all the event until while in prepare handoff mode,
  % on timeout or entering handoff mode all the event will be replayed
  {keep_state_and_data, [postpone]};

% handoff state
handle_event(enter, _PrevState, {?MODULE, {handoff, NewPid, StateName}}, State) ->
  NewTargetNode = node(NewPid),
  logger:info("~p (~p) starting handoff to ~p (~p)", [State#state.id, State#state.module, NewPid, NewTargetNode]),
  ok = gen_statem:call(NewPid, {?MODULE, {state_handoff, StateName, State}}, ?HANDOFF_TIMEOUT),
  logger:info("~p (~p) state transfered to ~p (~p)", [State#state.id, State#state.module, NewPid, NewTargetNode]),
  CatalogResult = pes:update(State#state.id, NewPid),
  logger:debug("~p (~p) catalog updated to ~p (~p) with: ~p", [State#state.id, State#state.module, NewPid, NewTargetNode, CatalogResult]),
  {keep_state, State, [{state_timeout, ?WAIT_FOR_LATE_MSG_TIMEOUT, stop}]};
handle_event(state_timeout, stop, {?MODULE, {handoff, _, _}}, #state{} = State) ->
  logger:debug("~p (~p) handoff timeout, stopping", [State#state.id, State#state.module]),
  {stop, normal, State};
handle_event(EventType, EventContext, {?MODULE, {handoff, NewPid, _}}, _State) ->
  % transfer all the request to the new pid during the handoff event
  NewPid ! {?MODULE, {handoff, EventType, EventContext}},
  {keep_state_and_data, [{state_timeout, ?WAIT_FOR_LATE_MSG_TIMEOUT, stop}]};

% receive handoff
handle_event(enter, _PrevState, {?MODULE, wait_for_handoff}, State) ->
  {keep_state, State, [{state_timeout, ?HANDOFF_TIMEOUT, stop}]};
handle_event({call, From}, {?MODULE, {state_handoff, StateName, State}}, {?MODULE, wait_for_handoff}, _State) ->
  {SourcePid, _} = From,
  SourcePidNode = node(SourcePid),
  logger:info("~p (~p) state received from ~p (~p)", [State#state.id, State#state.module, SourcePid, SourcePidNode]),
  bear_metrics:count([statem, handoff]),
  bear_metrics:count([statem, started]),
  bear_metrics:increase([statem, active]),
  {next_state, StateName, State, [{reply, From, ok}]};
handle_event(state_timeout, stop, {?MODULE, wait_for_handoff}, #state{} = State) ->
  {stop, no_handoff_received, State};
handle_event(EventType, _EventContext, {?MODULE, wait_for_handoff}, _State) when EventType =/= enter ->
  % postpone all the event until we received the handoff
  {keep_state_and_data, [postpone]};

handle_event(info, {?MODULE, {handoff, EventType, EventContext}}, StateName, State) ->
  handle_event(EventType, EventContext, StateName, State);
handle_event(internal, {?MODULE, state_initialized}, StateName, State) ->
  handle_event(enter, StateName, StateName, State);
handle_event(EventType, EventContent0, StateName, #state{module = Module, cb_data = CBData} = State) ->
  EventContent = maybe_convert_content(EventType, EventContent0),
  case apply(Module, handle_event, [EventType, EventContent, StateName, CBData]) of
    keep_state_and_data ->
      keep_state_and_data;
    {keep_state_and_data, Actions} ->
      {ok, NewActions, NewState} = process_actions(Actions, StateName, State),
      {keep_state, NewState, NewActions};
    {keep_state, NewCbData} ->
      NewState = State#state{cb_data = NewCbData},
      {keep_state, NewState};
    {keep_state, NewCbData, Actions} ->
      NewState = State#state{cb_data = NewCbData},
      {ok, NewActions, NewState1} = process_actions(Actions, StateName, NewState),
      {keep_state, NewState1, NewActions};
    {next_state, NextState, NewCbData} ->
      NewState = State#state{cb_data = NewCbData},
      {next_state, NextState, NewState};
    {next_state, NextState, NewCbData, Actions} ->
      NewState = State#state{cb_data = NewCbData},
      {ok, NewActions, NewState1} = process_actions(Actions, StateName, NewState),
      {next_state, NextState, NewState1, NewActions};
    {repeat_state, NewCbData} ->
      NewState = State#state{cb_data = NewCbData},
      {repeat_state, NewState};
    {repeat_state, NewCbData, Actions} ->
      NewState = State#state{cb_data = NewCbData},
      {ok, NewActions, NewState1} = process_actions(Actions, StateName, NewState),
      {repeat_state, NewState1, NewActions};
    repeat_state_and_data ->
      repeat_state_and_data;
    {repeat_state_and_data, Actions} ->
      {ok, NewActions, _NewState1} = process_actions(Actions, StateName, State),
      {repeat_state_and_data, NewActions};
    stop ->
      stop;
    {stop, Reason} ->
      {stop, Reason};
    {stop, Reason, NewCbData} ->
      {stop, Reason, State#state{cb_data = NewCbData}};
    {stop_and_reply, Reason, Replies} ->
      {stop_and_reply, Reason, Replies};
    {stop_and_reply, Reason, Replies, NewCbData} ->
      NewState = State#state{cb_data = NewCbData},
      {stop_and_reply, Reason, Replies, NewState}
  end.

%% @private
%% @doc This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
terminate(Reason, {?MODULE, {handoff, _, _}}, State) ->
  % after handoff no need to clean the data from db
  logger:debug("~p (~p) terminated, was in handoff with ~p", [State#state.id, State#state.module, Reason]),
  %bear_metrics:decrease([statem, active]),
  ok;
terminate(Reason, StateName, #state{module = Module, stored = Obj, cb_data = CBData} = State) ->
  Result = apply(Module, terminate, [Reason, StateName, CBData]),
  case Result of
    keep_data ->
      ok;
    _ ->
      ok = rico:remove(Obj)
  end,
  logger:debug("~p (~p) terminated with ~p", [State#state.id, State#state.module, Reason]),
  bear_metrics:decrease([statem, active]),
  Result;
terminate(Reason, _StateName, undefined) ->
  logger:debug("State handler terminated with ~p", [Reason]),
  bear_metrics:decrease([statem, active]),
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

save_state(StateName, #state{id = Id, module = Module, stored = undefined, cb_data = Data} = State) ->
  SData = encode_stored_state(#store_state{state_name = StateName, cb_data = Data}),
  NewObj = rico:new_obj(get_bucket(Module), state_key(Module, Id), SData),
  {ok, StoredObj} = rico:store(NewObj),
  logger:debug("~p (~p) Object state stored", [Id, Module]),
  State#state{stored = StoredObj};
save_state(StateName, #state{id = Id, module = Module, stored = Obj, cb_data = Data} = State) ->
  SData = encode_stored_state(#store_state{state_name = StateName, cb_data = Data}),
  NewObj = rico:value(Obj, SData),
  {ok, StoredObj} = rico:store(NewObj),
  logger:debug("~p (~p) Object state stored", [Id, Module]),
  State#state{stored = StoredObj}.

encode_stored_state(State) ->
  term_to_binary(State).

decode_stored_state(Bin) ->
  binary_to_term(Bin).

process_actions(Actions, StateName, State) ->
  case lists:member(save, Actions) of
    true ->
      {ok, lists:delete(save, Actions), save_state(StateName, State)};
    _ ->
      {ok, Actions, State}
  end.

maybe_convert_content(enter, {?MODULE, wait_for_handoff}) ->
  handoff;
maybe_convert_content(enter, {?MODULE, {prepare_handoff, _}}) ->
  handoff;
maybe_convert_content(enter, {?MODULE, {handoff, _NewPid, _StateName}}) ->
  handoff;
maybe_convert_content(_EventType, EventContent) ->
  EventContent.

-spec state_key(module(), term()) -> binary().
state_key(Module, Id) ->
  term_to_binary({Module, Id}).

-spec get_bucket(module()) -> rico:bucket().
get_bucket(Module) ->
  case erlang:function_exported(Module, bucket, 0) of
    true ->
      apply(Module, bucket, []);
    _ ->
      ?BUCKET
  end.
