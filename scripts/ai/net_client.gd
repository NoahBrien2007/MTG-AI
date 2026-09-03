class_name NetClient
extends RefCounted

## Blocking HTTP/JSON to the local model server (ai/python/mtgai/serve.py).
##
## Blocking on purpose: GameSession.run_sync() drives an entire game inside one
## call, so the scene tree never gets a frame and HTTPRequest — which is a Node
## and needs the tree to pump it — would simply never complete. Hence the raw
## HTTPClient poll loop. serve.py speaks HTTP/1.1, so the connection is reused
## across decisions instead of reconnecting every time.

## Generous: the first request pays for torch's lazy setup.
const TIMEOUT_MS := 10000

var host := "127.0.0.1"
var port := 8787
var requests_made := 0

var _client := HTTPClient.new()


## Agents are RefCounted and go away between games; without this the socket is
## dropped mid-keepalive and the server logs a reset for every one.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_client.close()


func url(path: String = "") -> String:
	return "http://%s:%d%s" % [host, port, path]


## Parsed JSON on success, null on any failure — callers decide what a failure
## means, because "the server is down" and "the answer was wrong" need different
## handling in an agent that must keep playing either way.
func post_json(path: String, body: Dictionary) -> Variant:
	return _request(HTTPClient.METHOD_POST, path, JSON.stringify(body))


func get_json(path: String) -> Variant:
	return _request(HTTPClient.METHOD_GET, path, "")


func _request(method: int, path: String, body: String) -> Variant:
	if not _ensure_connected():
		return null

	var headers := PackedStringArray(["Content-Type: application/json"])
	if _client.request(method, path, headers, body) != OK:
		_client.close()
		return null

	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if Time.get_ticks_msec() > deadline:
			_client.close()
			return null
		OS.delay_msec(1)

	if not _client.has_response() or _client.get_response_code() != 200:
		_client.close()
		return null

	var raw := PackedByteArray()
	while _client.get_status() == HTTPClient.STATUS_BODY:
		_client.poll()
		var chunk := _client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(1)
		else:
			raw.append_array(chunk)
		if Time.get_ticks_msec() > deadline:
			_client.close()
			return null

	requests_made += 1
	return JSON.parse_string(raw.get_string_from_utf8())


func _ensure_connected() -> bool:
	if _client.get_status() == HTTPClient.STATUS_CONNECTED:
		return true

	_client.close()
	if _client.connect_to_host(host, port) != OK:
		return false

	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() <= deadline:
		_client.poll()
		var status := _client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			return true
		# CANT_CONNECT / CANT_RESOLVE / DISCONNECTED — nothing is listening.
		if status != HTTPClient.STATUS_CONNECTING and status != HTTPClient.STATUS_RESOLVING:
			return false
		OS.delay_msec(1)
	return false
