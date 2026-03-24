# lua-https

lua-https is a simple Lua HTTPS module using native platform backends specifically written for LÖVE 12.0 and supports Windows, Linux, macOS, iOS, and Android.

lua-https is licensed under zLib license, same as LÖVE.

## Reference

To use lua-https, load it with `require`:

```lua
local https = require("https")
```

> Note: lua-https does not create global variables!

The `https` module exposes a single function: `https.request`

---

## Function 1: Simple Request

**Synopsis**

```lua
code, body = https.request(url)
```

**Arguments**

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | string | HTTP or HTTPS URL to access |

**Returns**

| Return Value | Type | Description |
|--------------|------|-------------|
| `code` | number | HTTP status code, or 0 on failure |
| `body` | string | HTTP response body or nil on failure |

---

## Function 2: Advanced Request

**Synopsis**

```lua
code, body, headers = https.request(url, options)
```

**Arguments**

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | string | HTTP or HTTPS URL to access |
| `options` | table | Options for advanced mode |

**Options Fields**

| Field | Type | Description |
|-------|------|-------------|
| `data` | string | Additional data to send as `application/x-www-form-urlencoded` (unless specified otherwise in Content-Type header) |
| `method` | string | HTTP method. If absent, it's either "GET" or "POST" depending on the data field above |
| `headers` | table | Additional headers to add to the request as key-value pairs |

**Returns**

| Return Value | Type | Description |
|--------------|------|-------------|
| `code` | number | HTTP status code, or 0 on failure |
| `body` | string | HTTP response body or nil on failure |
| `headers` | table | HTTP response headers as key-value pairs or nil on failure |

---

## Utility: URL Encoding

> **Tip**: To urlencode a Lua table suitable for `application/x-www-form-urlencoded` data, use a LuaSocket function.

```lua
local url = require("socket.url")

function urlencode(list)
    -- Since order of pairs is undefined, the key-value order is also undefined
    local result = {}
    for k, v in pairs(list) do
        result[#result + 1] = url.escape(k) .. "=" .. url.escape(v)
    end
    return table.concat(result, "&")
end

-- Usage
code, body, headers = https.request("https://example.com", {
    data = urlencode({key = "value", foo = "bar"})
})
```