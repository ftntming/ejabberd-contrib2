%%%-------------------------------------------------------------------
%%% File    : mod_rest.erl
%%% Author  : Nolan Eakins <sneakin@semanticgap.com>
%%% Purpose : Provide an HTTP interface to POST stanzas into ejabberd
%%%
%%% Copyright (C) 2008 Nolan Eakins
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%                         
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(mod_rest).
-author('sneakin@semanticgap.com').

-behavior(gen_mod).

-export([start/2,
	 stop/1,
	 depends/2,
	 split_line/1,
	 process/2,
	 mod_opt_type/1, mod_options/1, mod_doc/0]).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("ejabberd_ctl.hrl").
-include_lib("xmpp/include/xmpp.hrl").

start(_Host, _Opts) ->
    ?DEBUG("Starting: ~p ~p", [_Host, _Opts]),
    ok.

stop(_Host) ->
    ok.
    
depends(_Host, _Opts) ->
    [].

process([], #request{method = 'POST', data = Data, host = Host, ip = ClientIp}) ->
    try
	check_member_option(Host, ClientIp, allowed_ips),
	maybe_post_request(Data, Host, ClientIp)
    catch
	error:{badmatch, _} = Error ->
	    ?DEBUG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data, Error]),
	    {406, [], <<"Error: REST request is rejected by service.">>}
    end;
process(Path, Request) ->
    ?DEBUG("Got request to ~p: ~p", [Path, Request]),
    {200, [], <<"Try POSTing a stanza.">>}.


%% If the first character of Data is <, it is considered a stanza to deliver.
%% Otherwise, it is considered an ejabberd command to execute.
maybe_post_request(<<$<,_/binary>> = Data, Host, ClientIp) ->
    try
	Stanza = {xmlel, _, _, _} = fxml_stream:parse_element(Data),
	Pkt = xmpp:decode(Stanza),
	allowed = check_stanza(Pkt, Host),
	?DEBUG("Got valid request with IP ~p:~n~p",
		  [ClientIp,
		   Pkt]),
	post_request(Pkt)
    catch
	error:{badmatch, _} = Error ->
	    ?INFO_MSG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data, Error]),
	    {406, [], "Error: REST request is rejected by service."};
	error:{Reason, _} = Error ->
	    ?INFO_MSG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data, Error]),
	    {500, [], "Error: " ++ atom_to_list(Reason)};
	Error ->
	    ?INFO_MSG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data, Error]),
	    {500, [], "Error"}
    end;    
maybe_post_request(Data, Host, _ClientIp) ->
    ?INFO_MSG("Data: ~p", [Data]),
    Args = split_line(unicode:characters_to_list(Data, utf8)),
    Args2 = ensure_auth_is_provided(Args),
    AccessCommands = get_option_access(Host),
    case ejabberd_ctl:process2(Args2, AccessCommands) of
	{"", ?STATUS_SUCCESS} ->
	    {200, [], integer_to_list(?STATUS_SUCCESS)};
	{String, ?STATUS_SUCCESS} ->
	    {200, [], String};
	{"", Code} ->
	    {200, [], integer_to_list(Code)};
	{String, _Code} ->
	    {200, [], String}
    end.

ensure_auth_is_provided(["--auth", _, _, _ | _] = Args) ->
    Args;
ensure_auth_is_provided(Args) ->
    ["--auth", "", "", "" | Args].

%% This function throws an error if the module is not started in that VHost.
try_get_option(Host, OptionName) ->
    case gen_mod:is_loaded(Host, ?MODULE) of
	true -> ok;
	_ -> throw({module_must_be_started_in_vhost, ?MODULE, Host})
    end,
    gen_mod:get_module_opt(Host, ?MODULE, OptionName).

get_option_access(Host) ->
    try_get_option(Host, access_commands).

%% This function crashes if the stanza does not satisfy configured restrictions
check_stanza(Pkt, Host) ->
    To = xmpp:get_to(Pkt),
    check_member_option(Host, To, allowed_destinations),
    Name = xmpp:get_name(Pkt),
    check_member_option(Host, Name, allowed_stanza_types),
    allowed.

check_member_option(Host, ClientIp, allowed_ips) ->
    true = case try_get_option(Host, allowed_ips) of
               [] -> true;
               AllowedValues -> ip_matches(ClientIp, AllowedValues)
           end;
check_member_option(Host, Element, Option) ->
    true = case try_get_option(Host, Option) of
	       [] -> true;
	       AllowedValues -> lists:member(Element, AllowedValues)
	   end.

ip_matches({Address, _Port}, AllowedValues) ->
   lists:any(fun({Net, Mask}) ->
	      acl:match_acl(global, {ip,{Net,Mask}}, #{ip => Address})
	  end,
	  AllowedValues).

post_request(Pkt) ->
    From = xmpp:get_from(Pkt),
    LServer = From#jid.lserver,
    ejabberd_hooks:run_fold(user_send_packet, LServer, {Pkt, #{jid => From}}, []),
    ejabberd_router:route(Pkt),
    {200, [], <<"Ok">>}.

%% Split a line into args. Args are splitted by blankspaces. Args can be enclosed in "".
%%
%% Example call:
%% mod_rest:split_line("  a1 b2 \"c3 d4\"e5\" c6   d7 \\\"  e8\"f9   g0 \\\" h1  ").
%% ["a1","b2","c3 d4\"e5","c6","d7","  e8\"f9   g0 ","h1"]
%%
%% 32 is the integer that represents the blankspace
%% 34 is the integer that represents the double quotes: "
%% 92 is the integer that represents the backslash: \
split_line(Line) -> split(Line, "", []).
split("", "", Args) -> lists:reverse(Args);
split("", Arg, Args) -> split("", "", [lists:reverse(Arg) | Args]);
split([32 | Line], "", Args) -> split(Line, [], Args);
split([32 | Line], Arg, Args) -> split(Line, [], [lists:reverse(Arg) | Args]);
split([34 | Line], "", Args) -> {Line2, Arg2} = splitend(Line), split([32 | Line2], Arg2, Args);
split([92, 34 | Line], "", Args) -> {Line2, Arg2} = splitend(Line), split([32 | Line2], Arg2, Args);
split([Char | Line], Arg, Args) -> split(Line, [Char | Arg], Args).
splitend(Line) -> splitend(Line, []).
splitend([], Res) -> {"", Res};
splitend([34], Res) -> {"", Res};
splitend([92, 34], Res) -> {"", Res};
splitend([34, 32 | Line], Res) -> {Line, Res};
splitend([92, 34, 32 | Line], Res) -> {Line, Res};
splitend([Char | Line], Res) -> splitend(Line, [Char | Res]).

mod_opt_type(allowed_ips) ->
    econf:list(econf:ip_mask());
mod_opt_type(allowed_destinations) ->
    econf:list(econf:jid());
mod_opt_type(allowed_stanza_types) ->
    econf:list(econf:enum([<<"iq">>, <<"message">>, <<"presence">>]));
mod_opt_type(access_commands) ->
    fun (A) when is_list(A) -> A end.

mod_options(_Host) ->
    [{allowed_ips, []},
     {allowed_destinations, []},
     {allowed_stanza_types, []},
     {access_commands, []}].

mod_doc() -> #{}.
