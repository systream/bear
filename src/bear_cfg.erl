%%%-------------------------------------------------------------------
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_cfg).

%% API
-export([set/2, get/2, add_node/2, remove_node/2]).

-spec add_node(term(), node()) -> ok.
add_node(Key, Node) ->
  simple_gossip:set(fun(Data) ->
    SGKey = {?MODULE, Key},
    Nodes = maps:get(SGKey, Data, []),
    NewNodes =
      case lists:member(Node, Nodes) of
        true -> Nodes;
        _ -> [Node | Nodes]
      end,
    {change, Data#{SGKey => NewNodes}}
  end).

-spec remove_node(term(), node()) -> ok.
remove_node(Key, Node) ->
  simple_gossip:set(fun(Data) ->
    SGKey = {?MODULE, Key},
    Nodes = maps:get(SGKey, Data, []),
    NewNodes = lists:delete(Node, Nodes),
    {change, Data#{SGKey => NewNodes}}
  end).

-spec set(term(), term()) -> ok.
set(Key, Value) ->
  simple_gossip:set({?MODULE, Key}, Value).

-spec get(term(), term()) -> term().
get(Key, Default) ->
  simple_gossip:get({?MODULE, Key}, Default).
