#!/usr/bin/env escript
%%! -noinput
%% Fake {packet, 4} worker for PacketWorker tests. Usage: escript packet_worker.escript LOG
%% Logs "start" and "recv:<payload>" lines to LOG. Commands are payload prefixes:
%%   echo*      reply with the payload
%%   prob*      reply "0.75"
%%   slow:<ms>  sleep, then reply "slow"
%%   hang*      never reply; exit when stdin closes
%%   die*       exit with status 3
main([Log]) ->
    Port = open_port({fd, 0, 1}, [binary, {packet, 4}, eof]),
    log(Log, <<"start">>),
    Port ! {self(), {command, <<"ready">>}},
    loop(Port, Log).

loop(Port, Log) ->
    receive
        {Port, {data, Data}} ->
            log(Log, <<"recv:", Data/binary>>),
            handle(Port, Data),
            loop(Port, Log);
        {Port, eof} ->
            halt(0)
    end.

handle(Port, <<"echo", _/binary>> = Data) -> reply(Port, Data);
handle(Port, <<"prob", _/binary>>) -> reply(Port, <<"0.75">>);
handle(Port, <<"slow:", Rest/binary>>) ->
    [Ms | _] = binary:split(Rest, <<0>>),
    timer:sleep(binary_to_integer(Ms)),
    reply(Port, <<"slow">>);
handle(Port, <<"hang", _/binary>>) ->
    receive {Port, eof} -> halt(0) end;
handle(_Port, <<"die", _/binary>>) -> halt(3).

reply(Port, Data) -> Port ! {self(), {command, Data}}.

log(Log, Line) -> file:write_file(Log, [Line, $\n], [append]).
