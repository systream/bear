-module(bear_test_handler).
-behaviour(bear).
-export([init/1, handle_event/4, terminate/3]).

init([Id]) ->
    {ok, idle, #{id => Id, data => undefined, counter => 0}}.

handle_event({call, From}, get_data, _State, #{data := Data}) ->
    {keep_state_and_data, [{reply, From, Data}]};
handle_event({call, From}, {set_data, Data}, _State, StateData) ->
    NewStateData = StateData#{data => Data},
    {keep_state, NewStateData, [{reply, From, ok}]};
handle_event({call, From}, {set_data_and_save, Data}, _State, StateData) ->
    NewStateData = StateData#{data => Data},
    {keep_state, NewStateData, [{reply, From, ok}, save]};
handle_event({call, From}, inc_counter, _State, #{counter := C} = StateData) ->
    {keep_state, StateData#{counter => C + 1}, [{reply, From, C + 1}]};
handle_event(cast, {set_data_cast, Data}, _State, StateData) ->
    {keep_state, StateData#{data => Data}};
handle_event(cast, {set_data_cast_and_save, Data}, _State, StateData) ->
    {keep_state, StateData#{data => Data}, [save]};
handle_event(_Type, _Content, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, #{data := keep_me}) ->
    keep_data;
terminate(_Reason, _State, _Data) ->
    ok.
