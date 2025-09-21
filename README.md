bear
=====

rp([bear_gen_statem_manager:start_handler(<<"test_", (integer_to_binary(I))/binary>>, test_callb, [I+I]) || I <- lists:seq(1, 10)]).
rp([gen_statem:call({via, pes, <<"test_", (integer_to_binary(I))/binary>>}, {set, I+I*I}) || I <- lists:seq(1, 500)]).

rp([catch gen_statem:call({via, pes, <<"test_", (integer_to_binary(I))/binary>>}, {set, {node(), self(), erlang:unique_integer(), integer_to_binary(I+I*I)}}) || I <- lists:seq(1, 5500)]).
rp([catch gen_statem:stop({via, pes, <<"test_", (integer_to_binary(I))/binary>>}) || I <- lists:seq(1, 5500)]).

Build
-----

    $ rebar3 compile
