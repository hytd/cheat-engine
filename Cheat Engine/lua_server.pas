unit lua_server;
{
This unit will setup a communication to the lua engine
It will be responsible for receiving and dispatching messages

lua server waits for pipe connections and when made spawns a new thread(TLuaServerHandler) which
handles the communication while it itself is going back to listen to new connections.

}

{$mode delphi}

interface

uses
  jwawindows, windows, Classes, SysUtils, lua, lauxlib, lualib, LuaHandler;

type
  TLuaServerHandler=class(TThread)
  private
    pipe: THandle;
    exec: tstringlist;
    result: qword;

    returncount: byte;
    results: array of qword;
    procedure ExecuteLuaScript;
    procedure ExecuteLuaScriptVar;
    procedure ExecuteLuaFunction;
    procedure ExecuteScript;
  protected
    procedure execute; override;

  public
    constructor create(pipe: THandle);
    destructor destroy; override;
  end;

  TLuaServer=class(TThread)
  private
    fname: string;
  protected
    procedure execute; override;
  public
    constructor create(name: string);
    destructor destroy; override;
    property name: string read fname;
  end;

 // TLuaServers =  TFPGList<TLuaServer>;

var luaservers: TList;

function luaserverExists(name: string): boolean;

implementation

resourcestring
  rsALuaserverWithTheName = 'A luaserver with the name ';
  rsAlreadyExists = ' already exists';

type EPipeError=class(Exception);

function luaserverExists(name: string): boolean;
var i: integer;
begin
  result:=true;
  for i:=0 to luaservers.count-1 do
    if TLuaServer(luaservers[i]).name=name then exit;

  result:=false;
end;



//--------TLuaServerHandler--------

constructor TLuaServerHandler.create(pipe: THandle);
begin
  FreeOnTerminate:=true;
  self.pipe:=pipe;
  exec:=TStringlist.create;
  inherited create(false);
end;

destructor TLuaServerHandler.destroy;
begin
  exec.free;
  inherited destroy;
end;

procedure TLuaServerHandler.ExecuteScript;
var
  i,j: integer;
  top: integer;

begin
  LuaCS.Enter;
  try
    top:=lua_gettop(Luavm);
    i:=luahandler.lua_dostring(luavm, pchar(exec.text));
    if i=0 then
      result:=lua_tointeger(Luavm, -1)
    else
      result:=0;

    if returncount>0 then
    begin
      if length(results)<returncount then
        setlength(results, returncount);

      for i:=0 to returncount-1 do
        results[(returncount-1)-i]:=lua_tointeger(Luavm, -1-i);

    end;

    lua_settop(Luavm, top);

  finally
    luacs.leave;
  end;
end;


procedure TLuaServerHandler.ExecuteLuaFunction;
type TParamType=(ptNil=0, ptBoolean=1, ptInt64=2, ptNumber=3, ptString=4, ptTable=5);
{
todo: ExecuteLuaFunction
Variable paramcount
setup:
functionref: byte
if functionref=0 then
  functionnamelength: byte
  functionname[functionnamelength]: char
end

paramcount: byte
params[paramcount]: record
    paramtype: byte  - 0=nil, 1=integer64, 2=double, 3=string,  4=table perhaps ?
    value:
      --if paramtype=2 then
      stringlength: word
      string[strinbglength]: char
      --else
      value: 8byte
  end

returncount: byte


--returns:
actualreturncount: byte

}
  procedure error;
  begin
    OutputDebugString('Read error');
    terminate;
  end;

var
  functionref: integer;
  br: dword;
  functionname: pchar;
  functionnamelength: word;
  paramcount: byte;
  returncount: byte;

  paramtype: byte;

  value: qword;
  doublevalue: double absolute value;
  v8: byte absolute value;

  stringlength: word;
  tempstring: pchar;
  i,j,t: integer;

  valid: integer;

begin
  try

    if readfile(pipe, functionref, sizeof(functionref), br, nil)=false then raise EPipeError.Create('');

    if functionref<>0 then
    begin
      lua_rawgeti(Luavm, LUA_REGISTRYINDEX, functionref);
    end
    else
    begin
      if readfile(pipe, functionnamelength, sizeof(functionnamelength), br, nil)=false then raise EPipeError.Create('');

      getmem(functionname, functionnamelength+1);
      if readfile(pipe, functionname^, functionnamelength, br, nil)=false then raise EPipeError.Create('');

      functionname[functionnamelength]:=#0;

      lua_getglobal(Luavm, pchar(functionname));

      freemem(functionname);
    end;

    //the function is now pushed on the lua stack
    if readfile(pipe, paramcount, sizeof(paramcount), br, nil)=false then raise EPipeError.Create('');

    for i:=0 to paramcount-1 do
    begin
      if readfile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');

      case TParamType(paramtype) of
        ptNil: lua_pushnil(LuaVM);

        ptBoolean: //int
        begin
          if readfile(pipe, v8, sizeof(v8), br, nil)=false then raise EPipeError.Create('');
          lua_pushboolean(LuaVM, v8<>0);
        end;

        ptInt64: //int
        begin
          if readfile(pipe, value, sizeof(value), br, nil)=false then raise EPipeError.Create('');
          lua_pushinteger(LuaVM, value);
        end;

        ptNumber: //number
        begin
          if readfile(pipe, value, sizeof(value), br, nil)=false then raise EPipeError.Create('');
          lua_pushnumber(LuaVM, doublevalue);
        end;

        ptString: //string
        begin
          if readfile(pipe, stringlength, sizeof(stringlength), br, nil)=false then raise EPipeError.Create('');
          getmem(tempstring, stringlength+1);

          if readfile(pipe, tempstring[0], stringlength, br, nil)=false then raise EPipeError.Create('');

          tempstring[stringlength]:=#0;
          lua.lua_pushstring(LuaVM, tempstring);

          freemem(tempstring);
        end;

       { 4: //table
        begin
          lua_newtable(LuaVM);
          t:=lua_gettop(LuaVM);
          LoadLuaTable(t);
        end;   }
      end;

    end;

    if readfile(pipe, returncount, sizeof(returncount), br, nil)=false then raise EPipeError.Create('');


    if lua_pcall(LuaVM, paramcount, returncount, 0)=0 then
    begin
      writefile(pipe, returncount, sizeof(returncount), br,nil);
      for i:=0 to returncount-1 do
      begin
        j:=-returncount+i;

        case lua_type(LuaVM, j) of
          LUA_TNIL:
          begin
            paramtype:=byte(ptNil);
            if writefile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');
          end;

          LUA_TBOOLEAN:
          begin
            paramtype:=byte(ptBoolean);
            if writefile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');

            if lua_toboolean(Luavm, j) then v8:=1 else v8:=0;
            if writefile(pipe, v8, sizeof(v8), br, nil)=false then raise EPipeError.Create('');
          end;

          LUA_TNUMBER:
          begin
            valid:=0;
            value:=lua_tointegerx(Luavm,j,@valid);

            if valid<>0 then
            begin
              paramtype:=byte(ptInt64);
              if writefile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');
              if writefile(pipe, value, sizeof(value), br, nil)=false then raise EPipeError.Create('');
            end
            else
            begin
              paramtype:=byte(ptNumber);
              if writefile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');

              doublevalue:=lua_tonumber(LuaVM, j);
              if writefile(pipe, doublevalue, sizeof(doublevalue), br, nil)=false then raise EPipeError.Create('');
            end;
          end;

          LUA_TSTRING:
          begin
            paramtype:=byte(ptString);
            if writefile(pipe, paramtype, sizeof(paramtype), br, nil)=false then raise EPipeError.Create('');

            tempstring:=lua.Lua_ToString(LuaVM, j);
            stringlength:=length(tempstring);

            if writefile(pipe, tempstring[0], stringlength, br, nil)=false then raise EPipeError.Create('');
          end;
          {
          LUA_TNIL           = 0;
          LUA_TBOOLEAN       = 1;
          LUA_TLIGHTUSERDATA = 2;
          LUA_TNUMBER        = 3;
          LUA_TSTRING        = 4;
          LUA_TTABLE         = 5;
          LUA_TFUNCTION      = 6;
          LUA_TUSERDATA      = 7;
          LUA_TTHREAD        = 8;
          LUA_NUMTAGS        = 9;
          }
        end;

      end;

    end
    else
    begin
      writefile(pipe, returncount, sizeof(returncount), br,nil);
      returncount:=0;
    end;

  except
    error;
  end;
end;



procedure TLuaServerHandler.ExecuteLuaScriptVar;
{
Same as ExecuteLuaScript but can return more than one return value qword
}
  procedure error;
  begin
    OutputDebugString('Read error');
    terminate;
  end;

var
  scriptsize: integer;
  br: dword;
  script: pchar;

  parameter: qword;
  i: integer;
begin
  if readfile(pipe, scriptsize, sizeof(scriptsize), br, nil) then
  begin
    getmem(script, scriptsize+1);

    try
      if readfile(pipe, script^, scriptsize, br, nil) then
      begin
        script[scriptsize]:=#0;

        if readfile(pipe, parameter, 8, br, nil) then
        begin
          if readfile(pipe, returncount, 1, br, nil) then
          begin
            exec.clear;
            exec.Text:=script;

            exec.Insert(0, 'function _luaservercall'+inttostr(GetCurrentThreadId)+'(parameter)');
            exec.add('end');
            exec.add('return _luaservercall'+inttostr(GetCurrentThreadId)+'('+inttostr(parameter)+')');

            setlength(results, returncount);
            synchronize(executescript);

            for i:=0 to returncount-1 do
              if writefile(pipe, results[i], 8, br, nil)=false then error;

          end
          else error;
        end
        else
          error;
      end
      else
        error;

    finally
      freemem(script);
    end;
  end
  else
    error;

end;

procedure TLuaServerHandler.ExecuteLuaScript;
  procedure error;
  begin
    OutputDebugString('Read error');
    terminate;
  end;

var
  scriptsize: integer;
  br: dword;
  script: pchar;

  parameter: qword;
begin
  returncount:=1;
  if readfile(pipe, scriptsize, sizeof(scriptsize), br, nil) then
  begin
    getmem(script, scriptsize+1);

    try
      if readfile(pipe, script^, scriptsize, br, nil) then
      begin
        script[scriptsize]:=#0;

        if readfile(pipe, parameter, 8, br, nil) then
        begin
          exec.clear;
          exec.Text:=script;

          exec.Insert(0, 'function _luaservercall'+inttostr(GetCurrentThreadId)+'(parameter)');
          exec.add('end');
          exec.add('return _luaservercall'+inttostr(GetCurrentThreadId)+'('+inttostr(parameter)+')');

          synchronize(executescript);

          if writefile(pipe, result, 8, br, nil)=false then
            error;
        end
        else
          error;
      end
      else
        error;

    finally
      freemem(script);
    end;
  end
  else
    error;

end;

procedure TLuaServerHandler.execute;
var
  command: byte;
  br: dword;
begin
  try
    while not terminated do
    begin
      ReadFile(pipe, command, sizeof(command), br, nil);
      case command of
        1: ExecuteLuaScript;
        2: ExecuteLuaScriptVar;
        3: synchronize(ExecuteLuaFunction);
        else terminate;
      end;
    end;


  finally
    CloseHandle(pipe);
  end;
end;


//--------TLuaServer--------

procedure TLuaServer.execute;
var
  pipe: THandle;
  a: SECURITY_ATTRIBUTES;
begin
  while not terminated do
  begin
    ZeroMemory(@a, sizeof(a));
    a.nLength:=sizeof(a);
    a.bInheritHandle:=TRUE;

    //got this string from https://www.osronline.com/showThread.CFM?link=204207
    ConvertStringSecurityDescriptorToSecurityDescriptor('D:(D;;FA;;;NU)(A;;0x12019f;;;WD)(A;;0x12019f;;;CO)', SDDL_REVISION_1, a.lpSecurityDescriptor, nil);

    pipe:=CreateNamedPipe(pchar('\\.\pipe\'+name), PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, 255, 16, 8192, 0, @a );
    LocalFree(HLOCAL(a.lpSecurityDescriptor));


    if ConnectNamedPipe(pipe, nil) or (GetLastError = ERROR_PIPE_CONNECTED) then
    begin
      //connected
      //send this pipe of to the handler and create a new pipe
      TLuaServerHandler.create(pipe);
    end
    else
    begin
      OutputDebugString('Lua server connect error');
      CloseHandle(pipe); //failure, try again
    end;
  end;
end;

constructor TLuaServer.create(name: string);
var i: integer;
begin
  fname:=name;

  if luaserverExists(name) then
    raise exception.create(rsALuaserverWithTheName+name+rsAlreadyExists);

  luaservers.Add(self);


  inherited create(false);
end;

destructor TLuaServer.destroy;
begin
  inherited destroy;
end;

initialization
  luaservers:=TList.create;


end.

