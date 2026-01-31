%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%% @copyright 2025
%%% @end
%%%
%%% @doc
%%% Manager for distributed gen_statem processes in the Bear system.
%%% This module is responsible for:
%%% - Starting state machine handlers on appropriate nodes
%%% - Distributing state machines across the cluster
%%% - Handling node up/down events
%%% - Managing handoffs during cluster changes
%%%
%%% The manager uses consistent hashing to determine which node should host
%%% each state machine instance based on its ID, ensuring even distribution
%%% and minimal reshuffling when the cluster topology changes.
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_manager).

-behaviour(gen_server).

-define(DEFAULT_DIST_CHK_TIME, 185000).

%% API
-export([start_link/0, start_handler/3, distribute_handlers/0, distribute_handlers/1,
         drain_node/1, undrain_node/1]).

%% Types
-type node_name() :: node().
-type state_machine_id() :: term().
-type module_name() :: module().

-type node_list() :: [node_name()].

-define(START_HANDOFF_TIME, 30000).

-ifdef(TEST).
-export([on_node/1]).
-endif.

-export([active_nodes/0, drain_nodes/0]).

%%%===================================================================
%%% API
%%%===================================================================

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
  distribution_check_timer :: undefined | reference()
}).
-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts a new state machine handler on the appropriate node.
%% @param Id The unique identifier for the state machine.
%% @param Module The module implementing the state machine callbacks.
%% @param Args Initialization arguments for the state machine.
%% @returns The result of the remote call to start the child process.
-spec start_handler(Id :: state_machine_id(), Module :: module_name(), Args :: term()) ->
        {ok, pid()} | {error, term()}.
start_handler(Id, Module, Args) ->
  erpc:call(on_node(Id), bear_gen_statem_super_sup, start_child, [Id, Module, Args]).

%% @doc Triggers redistribution of state machines across available nodes.
%% This function is typically called when the cluster topology changes
%% (nodes are added or removed) to rebalance the state machine distribution.
%% @returns ok if the redistribution was triggered successfully.
-spec distribute_handlers() -> ok.
distribute_handlers() ->
  gen_server:call(?SERVER, distribute_handlers, infinity).

-spec distribute_handlers([node()]) -> ok.
distribute_handlers(Nodes) ->
  gen_server:call(?SERVER, {distribute_handlers, Nodes}, infinity).

-spec drain_node(node()) -> ok.
drain_node(Node) ->
  bear_cfg:add_node(drain_nodes, Node),
  ActiveNodes = active_nodes(),
  distribute_handlers_on_all_nodes(ActiveNodes).

-spec undrain_node(node()) -> ok.
undrain_node(Node) ->
  bear_cfg:remove_node(drain_nodes, Node),
  distribute_handlers_on_all_nodes(active_nodes()).

-spec distribute_handlers_on_all_nodes([node()]) -> ok.
distribute_handlers_on_all_nodes(ActiveNodes) ->
  distribute_handlers_on_all_nodes(current_nodes(), ActiveNodes).

-spec distribute_handlers_on_all_nodes([node()], [node()]) -> ok.
distribute_handlers_on_all_nodes(Nodes, ActiveNodes) ->
  {_, []} =
    gen_server:multi_call(Nodes, ?SERVER, {distribute_handlers, ActiveNodes}, infinity),
  ok.

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  erlang:process_flag(trap_exit, true),
  net_kernel:monitor_nodes(true),
  {ok, schedule_distribution_check(#state{})}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: state()) ->
  {reply, Reply :: term(), NewState :: state()} |
  {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
  {stop, Reason :: term(), NewState :: state()}).
handle_call(distribute_handlers, _From, State = #state{}) ->
  NewState = cancel_distribution_check(State),
  trigger_reallocate(),
  {reply, ok, schedule_distribution_check(NewState)};
handle_call({distribute_handlers, Nodes}, _From, State = #state{}) ->
  NewState = cancel_distribution_check(State),
  trigger_reallocate(Nodes),
  {reply, ok, schedule_distribution_check(NewState)}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
handle_info({nodeup, Node}, State = #state{}) ->
  logger:info("Node ~p became online", [Node]),
  NewState = cancel_distribution_check(State),
  % wait a but to have all the data replicated to the new nodes
  wait_until_app_started(Node, bear),
  % wait that pes heal the data with heartbeat
  % @TODO is this right?
  timer:sleep(pes_cfg:heartbeat() + 100),
  trigger_reallocate(),
  {noreply, schedule_distribution_check(NewState)};
handle_info({nodedown, Node}, State = #state{}) ->
  % in case of down we do not know that it is a network split or a normal down, so do nothing
  logger:debug("Node ~p become unavailable", [Node]),
  {noreply, State};
handle_info(distribution_check, State = #state{}) ->
  logger:debug("Distribution check", []),
  Processes = bear_gen_statem_super_sup:children(),
  case should_trigger_distribution(Processes, active_nodes()) of
    true ->
      logger:info("Auto process distribute triggered", []),
      trigger_reallocate(),
      ok;
    _ ->
      logger:debug("No need to auto distribute processes", []),
      ok
  end,
  {noreply, schedule_distribution_check(State)}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: state()) -> term()).
terminate(_Reason, State = #state{}) ->
  cancel_distribution_check(State),
  trigger_reallocate(active_nodes() -- [node()]),
  bear_cfg:remove_node(drain_nodes, node()),
  ok.

should_trigger_distribution(Processes, NodeList) ->
  NodeDistribution = lists:foldl(fun({Id, _Pid, _Modules}, Acc) ->
                                   OnNode = on_node(Id, NodeList),
                                   Acc#{OnNode => maps:get(on_node, Acc, 0) + 1}
                                 end, #{}, Processes),
  DistributionTolerancePercentage = 10,
  CurrentNodeLoad = maps:get(node(), NodeDistribution, 0),
  Tolerance = max(100, (CurrentNodeLoad div 100) * DistributionTolerancePercentage),
  lists:any(fun({_, Pc}) -> Pc > Tolerance end, maps:to_list(maps:remove(node, NodeDistribution))).

schedule_distribution_check(#state{distribution_check_timer = undefined} = State) ->
  CheckTime = application:get_env(bear, distribution_check_time, ?DEFAULT_DIST_CHK_TIME),
  Ref = erlang:send_after(CheckTime, self(), distribution_check),
  State#state{distribution_check_timer = Ref};
schedule_distribution_check(State) ->
  schedule_distribution_check(cancel_distribution_check(State)).

cancel_distribution_check(#state{distribution_check_timer = undefined} = State) ->
  State;
cancel_distribution_check(#state{distribution_check_timer = Ref} = State) ->
  erlang:cancel_timer(Ref),
  State#state{distribution_check_timer = undefined}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Determines which node should host the state machine with the given ID.
%% Uses consistent hashing to map the ID to a node in the cluster.
%% @param Id The state machine ID.
%% @returns The node that should host this state machine.
-spec on_node(Id :: state_machine_id()) -> node_name().
on_node(Id) ->
  on_node(Id, active_nodes()).

%% @doc Determines which node should host the state machine with the given ID
%% from the specified node list.
%% @param Id The state machine ID.
%% @param NodeList List of available nodes.
%% @returns The node that should host this state machine.
-spec on_node(Id :: state_machine_id(), NodeList :: node_list()) -> node_name().
on_node(Id, NodeList0) ->
  NodeList = lists:sort(NodeList0),
  NodeLength = length(NodeList),
  lists:nth(erlang:phash2(Id, NodeLength) + 1, NodeList).

%% @doc Retrieves the current list of live nodes in the cluster.
%% @returns Sorted list of live nodes.
-spec current_nodes() -> node_list().
current_nodes() ->
  pes:live_nodes().

%% @doc return with all the active nodes without the draining nodes
%% @returns Sorted list of active nodes
-spec active_nodes() -> node_list().
active_nodes() ->
  DrainNodes = drain_nodes(),
  lists:filter(fun (Node) -> not lists:member(Node, DrainNodes) end, current_nodes()).

-spec drain_nodes() -> [node()].
drain_nodes() ->
  bear_cfg:get(drain_nodes, []).

%% @doc Triggers reallocation of state machines across all live nodes.
%% @see trigger_reallocate/1
trigger_reallocate() ->
  trigger_reallocate(active_nodes()).

%% @doc Triggers reallocation of state machines to the specified nodes.
%% @param NodeList List of target nodes for reallocation.
-spec trigger_reallocate(NodeList :: node_list()) -> ok.
trigger_reallocate([]) ->
  logger:warning("Reallocation triggered, but nowhere to reloacte", []),
  ok;
trigger_reallocate(NodeList) ->
  logger:info("Reallocation triggered", []),
  lists:foreach(fun({Id, Pid, [Module]}) ->
                   do_handoff(Id, Pid, NodeList, Module)
                end, bear_gen_statem_super_sup:children()).

%% @doc Waits until the specified application is running on the given node.
%% @param OnNode The node to check.
%% @param App The application name.
%% @returns ok when the application is running.
-spec wait_until_app_started(OnNode :: node_name(), App :: atom()) -> ok.
wait_until_app_started(OnNode, App) ->
  case rpc:call(OnNode, application_controller, is_running, [App]) of
    false ->
      timer:sleep(100),
      wait_until_app_started(OnNode, App);
    _ ->
      ok
  end.

%% @doc Handles the handoff of a state machine to a new node if needed.
%% @param Id The state machine ID.
%% @param Pid The process ID of the state machine.
%% @param NodeList List of available nodes.
%% @param Module The module implementing the state machine.
%% @returns ok if the handoff was successful or not needed.
-spec do_handoff(Id :: state_machine_id(), Pid :: pid(), NodeList :: node_list(), Module :: module_name()) -> ok.
do_handoff(Id, Pid, NodeList, Module) ->
  case on_node(Id, NodeList) of
    Node when node() =:= Node ->
      logger:debug("~p should stay on ~p", [Id, Node]),
      ok;
    NewNode ->
      logger:info("~p should be reallocated to ~p", [Id, NewNode]),
      try bear_gen_statem_handler:handoff(Pid) of
        ok ->
          case erpc:call(NewNode, bear_gen_statem_super_sup, start_handoff, [Id, Module], ?START_HANDOFF_TIME) of
            {ok, _NewPid} ->
              ok;
            {error, Reason} ->
              logger:error("Failed to start handoff for ~p on ~p: ~p", [Id, NewNode, Reason]),
              ok
          end
      catch
        exit:{noproc, _}:_ ->  % at the mean time the process gone, it is a normal phenomenon
          ok;
        Type:Error:Stacktrace ->
        logger:warning("Handoff crashed for ~p, ~p", [Id, {Type, Error, Stacktrace}]),
        ok
      end
  end.