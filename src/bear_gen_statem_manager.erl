%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_manager).

-behaviour(gen_server).

%% API
-export([start_link/0, start_handler/3, distribute_handlers/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_handler(Id, Module, Args) ->
  Node = on_node(Id),
  rpc:call(Node, bear_gen_statem_sup, start_child, [Id, Module, Args]).

distribute_handlers() ->
  gen_server:call(?SERVER, distribute_handlers, infinity).

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
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  erlang:process_flag(trap_exit, true),
  net_kernel:monitor_nodes(true),
  {ok, #state{}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(distribute_handlers, _From, State = #state{}) ->
  trigger_reallocate(),
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({nodeup, Node}, State = #state{}) ->
  logger:info("Node ~p became online", [Node]),
  % wait a but to have all the data replicated to the new nodes
  wait_until_app_started(Node, bear),
  % wait that pes heal the data with heartbeat
  % @TODO is this right?
  timer:sleep(pes_cfg:heartbeat() + 100),
  trigger_reallocate(),
  {noreply, State};
handle_info({nodedown, Node}, State = #state{}) ->
  % in case of down we do not know that it is a network split or a normal down, so do nothing
  logger:debug("Node ~p become unavailable", [Node]),
  {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
  trigger_reallocate(current_nodes() -- [node()]),
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

on_node(Id) ->
  on_node(Id, current_nodes()).

on_node(Id, NodeList) ->
  NodeLength = length(NodeList),
  lists:nth(erlang:phash2(Id, NodeLength) + 1, NodeList).

current_nodes() ->
  lists:sort(nodes([visible, this])).

trigger_reallocate() ->
  trigger_reallocate(current_nodes()).

trigger_reallocate(NodeList) ->
  logger:debug("Reallocation triggered", []),
  lists:foreach(fun({Id, Pid, [Module]}) ->
                   do_handoff(Id, Pid, NodeList, Module),
                   timer:sleep(length(NodeList) * 5)
                end, bear_gen_statem_sup:children()).

wait_until_app_started(OnNode, App) ->
  case rpc:call(OnNode, application_controller, is_running, [App]) of
    false ->
      timer:sleep(100),
      wait_until_app_started(OnNode, App);
    _ ->
      ok
  end.

do_handoff(Id, Pid, NodeList, Module) ->
  case on_node(Id, NodeList) of
    Node when node() =:= Node ->
      logger:debug("~ p should stay on ~p", [Id, Node]),
      ok;
    NewNode ->
      logger:info("~ p should be reallocated to ~p", [Id, NewNode]),
      case catch bear_gen_statem_handler:handoff(Pid) of
        ok ->
          {ok, _NewPid} = rpc:call(NewNode, bear_gen_statem_sup, start_handoff, [Id, Module]),
          ok;
        Reason ->
          % it means something wrong with this pid won't be able to handoff, lets just start
          logger:warning("Handoff failed for ~p, reason: ~p", [Id, Reason]),
          ok
      end
  end.