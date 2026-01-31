%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%% Main API module for the Bear distributed state machine system.
%%% This module provides a clean interface for managing and interacting
%%% with distributed state machines across the cluster.
%%% @end
%%%-------------------------------------------------------------------
-module(bear).

-define(DEFAULT_TIMEOUT, 5000).

-export([
  start_link/3,
  call/2, call/3,
  cast/2,
  stop/1, stop/2,
  reply/1,
  distribute_handlers/0,
  status/0]).

-export([drain_node/1, undrain_node/1]).

%% Type definitions
-type state() :: term().
-type data() :: term().
-type state_enter_result(State) :: gen_statem:state_enter_result(State).
-type event_type() :: gen_statem:event_type().
-type event_content() :: term().
-type event_handler_result(State) :: gen_statem:event_handler_result(State).
-type init_result(State) :: gen_statem:init_result(State).
-type id() :: term().
-type call_reply() :: term().
-type call_reply_action() :: {'reply', From :: term(), call_reply()}.

%% Callback definitions
-callback bucket() -> rico:bucket().
-callback init(Args :: term()) -> init_result(state()).

-callback handle_event(
    'enter',
    OldState :: state(),
    CurrentState :: state(),
    data()) ->
  state_enter_result(state());
    (event_type(),
     event_content(),
     CurrentState :: state(),
     data()) ->
  event_handler_result(state()).

-callback terminate(
    Reason :: 'normal' | 'shutdown' | {'shutdown', term()} | term(),
    CurrentState :: state(),
    data()) ->
  any().

-optional_callbacks([bucket/0]).

-export_type([id/0, call_reply_action/0]).
%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts a new state machine with the given ID, module, and arguments.
%% The state machine will be started on an appropriate node in the cluster.
%% @end
-spec start_link(id(), module(), term()) -> {ok, pid()} | {error, term()}.
start_link(Id, Module, Args) ->
    bear_gen_statem_manager:start_handler(Id, Module, Args).

%% @doc Makes a synchronous call to the state machine with the given ID.
%% Uses the default timeout (5000ms).
-spec call(id(), term()) -> term().
call(Id, Request) ->
    call(Id, Request, ?DEFAULT_TIMEOUT).

%% @doc Makes a synchronous call to the state machine with the given ID and timeout.
-spec call(id(), term(), timeout()) -> term().
call(Id, Request, Timeout) ->
    bear_gen_statem_handler:call(Id, Request, Timeout).

%% @doc Makes an asynchronous cast to the state machine with the given ID.
-spec cast(id(), term()) -> ok.
cast(Id, Request) ->
    gen_statem:cast({via, pes, Id}, Request).

%% @doc Stops the state machine with the given ID.
%% Uses the default reason 'normal'.
-spec stop(id()) -> ok.
stop(Id) ->
    stop(Id, normal).

%% @doc Stops the state machine with the given ID and reason.
-spec stop(id(), term()) -> ok.
stop(Id, Reason) ->
    gen_statem:stop({via, pes, Id}, Reason, infinity).

%% @doc Sends a reply to a client that called gen_statem:reply/2.
-spec reply(call_reply_action()) -> ok.
reply(Reply) ->
    gen_statem:reply(Reply).

%% @doc Distributes all handlers across the cluster for load balancing.
-spec distribute_handlers() -> ok | {error, term()}.
distribute_handlers() ->
    bear_gen_statem_manager:distribute_handlers().

-spec drain_node(node()) -> ok.
drain_node(Node) ->
    bear_gen_statem_manager:drain_node(Node).

-spec undrain_node(node()) -> ok.
undrain_node(Node) ->
  bear_gen_statem_manager:undrain_node(Node).

-spec status() -> #{'distribution' => #{node() => neg_integer()},
                    'total' => non_neg_integer(),
                    cluster => #{nodes => [node()],
                                dead_nodes => [node()],
                                active_nodes => [node()],
                                drain_nodes => [node()]}}.
status() ->
  ClusterNodes = pes:nodes(),
  LiveClusterNodes = pes:live_nodes(),
  Nodes = bear_gen_statem_manager:active_nodes(),
  DrainNodes = bear_gen_statem_manager:drain_nodes(),
  ProcessDistribution =
    bear_pmap:execute(fun(Node) ->
                        {Node, erpc:call(Node, bear_gen_statem_super_sup, children_count, [], 30000)}
                      end, LiveClusterNodes),
  Total = lists:foldl(fun({_, Count}, Acc) when is_number(Count) ->
                        Count + Acc;
                         (_, Acc) -> Acc
                      end, 0, ProcessDistribution),
  #{cluster => #{nodes => ClusterNodes,
                 dead_nodes => ClusterNodes -- LiveClusterNodes,
                 active_nodes => Nodes,
                 drain_nodes => DrainNodes},
    distribution => ProcessDistribution,
    total => Total
  }.
