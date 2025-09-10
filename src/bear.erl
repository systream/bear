%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 22. aug. 2025 20:24
%%%-------------------------------------------------------------------
-module(bear).

-type state() :: term().
-type data() :: term().
-type state_enter_result(State) :: gen_statem:state_enter_result(State).
-type event_type() :: gen_statem:event_type().
-type event_content() :: term().
-type event_handler_result(State) :: gen_statem:event_handler_result(State).
-type init_result(State) :: gen_statem:init_result(State).

-callback init(Args :: term()) -> init_result(state()).

-callback handle_event(
    'enter',
    OldState :: state(),
    CurrentState,
    data()) ->
  state_enter_result(CurrentState);
    (event_type(),
        event_content(),
        CurrentState :: state(),
        data()) ->
  event_handler_result(state()). % New state

-callback terminate(
    Reason :: 'normal' | 'shutdown' | {'shutdown', term()}
    | term(),
    CurrentState :: state(),
    data()) ->
  any().

%% API
-export([]).

start_link(Id, Module, Args) ->
  bear_gen_statem_manager:start_handler(Id, Module, Args).


