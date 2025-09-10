%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_handler).

-behaviour(gen_statem).

-define(HANDOFF_TIMEOUT, 3000).
-define(BUCKET, <<"bear">>).

%% API
-export([start_link/4, handoff/2]).

%% gen_statem callbacks
-export([init/1, handle_event/4, terminate/3, callback_mode/0]).

-record(state, {
  id :: binary(),
  module :: module(),
  stored :: bear_backend:obj() | undefined,
  cb_data :: term()
}).

%-type state() :: #state{}.

-record(store_state, {
  cb_data :: term(),
  state_name :: term()
}).

%%%===================================================================
%%% API
%%%===================================================================

handoff(Id, NewPid) ->
  call(Id, {handoff, NewPid}).

call(Server, Command) when is_pid(Server) ->
  gen_statem:call(Server, Command);
call(Id, Command) ->
  gen_statem:call({via, pes, Id}, Command).

%% @doc Creates a gen_statem process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
start_link(Register, Id, Module, Args) ->
  gen_statem:start_link(?MODULE, [Register, Id, Module, Args], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%% @private
%% @doc Whenever a gen_statem is started using gen_statem:start/[3,4] or
%% gen_statem:start_link/[3,4], this function is called by the new
%% process to initialize.
init([Id, Module, Args]) ->
  case pes:whereis_name(Id) of
    undefined ->
      yes = pes:register_name(Id, self()),
      init([Id, Module, Args]);
    Pid ->
      case catch gen_statem:call(Pid, in_handoff) of
        yes ->
          init([Id, Module, Args]);
        _ ->
          {stop, already_started}
      end
  end;
init([Id, Module, Args]) ->
  case bear_backend:fetch(?BUCKET, Id) of
    {ok, Obj} ->
      io:format(user, "[~p - ~p] state fatched from backed~n", [Id, self()]),
      #store_state{cb_data = CbData, state_name = StateName} = decode_stored_state(bear_backend:value(Obj)),
      io:format(user, "[~p - ~p] started from stored state~n", [Id, self()]),
      Data = #state{id = Id, stored = Obj, module = Module, cb_data = CbData},
      %erlang:process_flag(trap_exit, true),
      {ok, StateName, Data};
    not_found ->
      case apply(Module, init, [Args]) of
        {ok, StateName, Data, Actions} ->
          io:format(user, "[~p - ~p] started from initilzed state~n", [Id, self()]),
          State = #state{id = Id, module = Module, cb_data = Data},
          {ok, StateName, save_state(StateName, State), Actions};
        {ok, StateName, Data} ->
          io:format(user, "[~p - ~p] started from initilzed state~n", [Id, self()]),
          State = #state{id = Id, module = Module, cb_data = Data},
          {ok, StateName, save_state(StateName, State)}
      end;
    {error, Error} ->
      {error, {failed_to_fetch_state, Error}}
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

handle_event({call, From}, {handoff, NewPid}, _StateName, State = #state{}) ->
  io:format(user, "[~p - ~p] handoff command received ~n", [State#state.id, self()]),
  gen_statem:reply(From, ok),
  {next_state, {handoff, NewPid}, State};

% handoff state
handle_event(enter, _PrevState, {handoff, _NewPid}, State) ->
  {keep_state, State, [{state_timeout, ?HANDOFF_TIMEOUT, stop}]};

handle_event({call, From}, {ready_to_receive, NewPid}, {handoff, NewPid}, #state{} = State) ->
  gen_statem:reply(From, ok),
  io:format(user, "[~p - ~p] handoff to ~p~n", [State#state.id, self(), NewPid]),
  ok = gen_statem:call(NewPid, {state_handoff, PrevState, State}),
  io:format(user, "[~p - ~p] state transferred to ~p~n", [State#state.id, self(), NewPid]),
  A = pes:update(State#state.id, NewPid),
  io:format(user, "pes: ~p~n", [A]),
  io:format(user, "[~p - ~p] pes catalog updated to ~p~n", [State#state.id, self(), NewPid]),
  keep_state_and_data;
handle_event({call, From}, {ready_to_receive, _Pid}, _, #state{} = _State) ->
  gen_statem:reply(From, {error, not_in_handoff_or_target_pid_mismatch}),
  keep_state_and_data;
handle_event(state_timeout, stop, {handoff, _}, #state{} = State) ->
  {stop, normal, State};
handle_event(EventType, EventContext, {handoff, NewPid}, _State) ->
  NewPid ! {handoff, EventType, EventContext},
  keep_state_and_data;

% receive handoff
% @todo only in wait for handoff state
handle_event({call, From}, {state_handoff, StateName, State}, _, _State) ->
  io:format(user, "[~p - ~p] state received ~n", [State#state.id, self()]),
  {next_state, StateName, State, [{reply, From, ok}]};
handle_event(info, {handoff, EventType, EventContext}, StateName, State) ->
  io:format(user, "[~p - ~p] got handoff event ~n", [State#state.id, self()]),
  handle_event(EventType, EventContext, StateName, State);

handle_event(EventType, EventContent, StateName, #state{module = Module, cb_data = CBData} = State) ->
  case apply(Module, handle_event, [EventType, EventContent, StateName, CBData]) of
    keep_state_and_data ->
      keep_state_and_data;
    {keep_state_and_data, Actions} ->
      {ok, NewActions, NewState} = process_actions(Actions, StateName, State),
      {keep_state, NewState, NewActions};
    {keep_state, NewCbData, Actions} ->
      NewState = State#state{cb_data = NewCbData},
      {ok, NewActions, NewState1} = process_actions(Actions, StateName, NewState),
      {keep_state, NewState1, NewActions}
  end.

%% @private
%% @doc This function is called by a gen_statem when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_statem terminates with
%% Reason. The return value is ignored.
terminate(_Reason, {handoff, _}, _State) ->
  ok;
terminate(Reason, StateName, State = #state{module = Module, stored = Obj, cb_data = CBData}) ->
  io:format(user, "[~p - ~p] terminated ~p~n", [State#state.id, self(), Reason]),
  Result = apply(Module, terminate, [Reason, StateName, CBData]),
  ok = bear_backend:remove(Obj),
  Result.

%%%===================================================================
%%% Internal functions
%%%===================================================================

save_state(StateName, #state{id = Id, stored = undefined, cb_data = Data} = State) ->
  SData = encode_stored_state(#store_state{state_name = StateName, cb_data = Data}),
  NewObj = bear_backend:new_obj(?BUCKET, Id, SData),
  {ok, StoredObj} = bear_backend:store(NewObj),
  State#state{stored = StoredObj};
save_state(StateName, #state{stored = Obj, cb_data = Data} = State) ->
  SData = encode_stored_state(#store_state{state_name = StateName, cb_data = Data}),
  NewObj = bear_backend:value(Obj, SData),
  {ok, StoredObj} = bear_backend:store(NewObj),
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