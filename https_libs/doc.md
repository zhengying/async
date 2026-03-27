# lua-https

lua-https is a simple Lua HTTPS module using native platform backends
specifically written for [LÖVE](https://love2d.org) 12.0 and supports
Windows, Linux, macOS, iOS, and Android.

## Reference

To use lua-https, load it with require like `local https = require("https")`.
lua-https does not create global variables!

The https module exposes a single function: `https.request`.

## Synopsis

Basic form:

```lua
code, body = https.request( url )
```

Advanced form:

```lua
code, body, headers = https.request( url, options )
```

Callback form (streaming):

```lua
ok, err = https.request( url, options, callback, context )
```

### Arguments

* string `url`: HTTP or HTTPS URL to access.
* table `options`: Optional options for advanced mode.
  * string `data`: Additional data to send as application/x-www-form-urlencoded (unless specified otherwise in Content-Type header).
  * string `method`: HTTP method. If absent, it's either "GET" or "POST" depending on the data field above.
  * table `headers`: Additional headers to add to the request as key-value pairs.
* table or userdata `callback`: Optional callback target for streaming.
  * `response(context, status, headers)`: Called once when status and headers are available.
  * `body(context, chunk)`: Called one or more times as body chunks arrive. Return `false, "message"` to abort.
  * `complete(context, err)`: Called once at the end. `err` is `nil` on success.
* any `context`: Optional user value passed as first argument to all callback functions.

### Return values

Basic/advanced mode:

* number `code`: HTTP status code.
* string `body`: HTTP response body.
* table `headers`: HTTP response headers as key-value pairs in advanced mode only.

On failure in basic/advanced mode:

* nil, string `err`

Callback mode:

* boolean `ok`: `true` on success.
* string `err`: non-nil on failure, otherwise `nil`.

## Migration

Old basic usage:

```lua
local code, body = https.request("https://example.com")
if not code then
	error(body)
end
```

New callback usage:

```lua
local state = { chunks = {} }
local ok, err = https.request("https://example.com", {}, {
	body = function(context, chunk)
		context.chunks[#context.chunks + 1] = chunk
		return true
	end,
	complete = function(context, completeErr)
		context.err = completeErr
	end
}, state)

if not ok then
	error(err)
end

local body = table.concat(state.chunks)
```

Old advanced usage:

```lua
local code, body, headers = https.request("https://example.com", {
	method = "GET",
	headers = { ["Accept"] = "application/json" }
})
```

New callback usage with response metadata:

```lua
local state = {}
local ok, err = https.request("https://example.com", {
	method = "GET",
	headers = { ["Accept"] = "application/json" }
}, {
	response = function(context, status, headers)
		context.status = status
		context.headers = headers
	end,
	body = function(context, chunk)
		context.body = (context.body or "") .. chunk
		return true
	end
}, state)

assert(ok, err)
print(state.status, state.headers["content-type"])
```

## Callback Notes

* Header keys passed to `response` are lowercase.
* If `body` is not provided, callback mode still works.
* If `complete` is not provided, callback mode still works.
* Callback lookup supports metatable-based class/object style (`__index`).
* Callback mode only works on backends that support streaming callbacks.
* Callback mode is currently supported on Apple backends (macOS and iOS), WinINet on Windows, and the shared connection-based backends.
* Android does not yet support true streaming callbacks.

## Platform Support

* macOS / iOS: Supported through the Apple NSURL backend.
* Windows: Supported through WinINet and the shared connection-based backends.
* Linux: Supported through the shared connection-based backends and cURL when available.
* Android: Basic and advanced request modes work, but true streaming callback mode is not implemented yet.

## Examples

Basic:

```lua
local https = require("https")
local code, body = https.request("https://example.com")
assert(code == 200, body)
```

Advanced:

```lua
local https = require("https")
local code, body, headers = https.request("https://example.com", {
	method = "GET",
	headers = {
		["User-Agent"] = "lua-https"
	}
})
assert(code == 200, body)
print(headers["content-type"] or headers["Content-Type"])
```

Streaming with progress:

```lua
local https = require("https")

local state = { received = 0, total = 0 }
local ok, err = https.request("https://example.com/file", {}, {
	response = function(context, status, headers)
		print("status", status)
		context.total = tonumber(headers["content-length"]) or 0
	end,
	body = function(context, chunk)
		context.received = context.received + #chunk
		if context.total > 0 then
			print(string.format("%.2f%%", context.received * 100 / context.total))
		end
		return true
	end,
	complete = function(context, completeErr)
		if completeErr then
			print("failed:", completeErr)
		else
			print("done")
		end
	end
}, state)

assert(ok, err)
```

Class/object style callbacks:

```lua
local https = require("https")

local Downloader = {}
Downloader.__index = Downloader

function Downloader:response(status, headers)
	self.status = status
	self.total = tonumber(headers["content-length"]) or 0
	self.received = 0
end

function Downloader:body(chunk)
	self.received = self.received + #chunk
	return true
end

function Downloader:complete(err)
	self.error = err
end

local instance = setmetatable({}, Downloader)
local ok, err = https.request("https://example.com", {}, Downloader, instance)
assert(ok, err)
```
