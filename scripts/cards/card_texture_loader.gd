extends Node

## Autoload "CardTextures": fetches card art from Scryfall, caches it in memory
## and on disk (user://card_cache/). Falls back gracefully when offline — the
## card nodes show their name/type text until a texture arrives.

const CACHE_DIR := "user://card_cache/"
const SCRYFALL_URL := "https://api.scryfall.com/cards/named?fuzzy=%s&format=image&version=normal"
# Scryfall asks for a descriptive User-Agent and ~10 requests per second at most.
var _request_headers := PackedStringArray(["User-Agent: MTG-AI-Godot/0.1", "Accept: */*"])
const REQUEST_INTERVAL := 0.12

var _cache: Dictionary = {}     # key -> Texture2D
var _pending: Dictionary = {}   # key -> Array[Callable]
var _failed: Dictionary = {}    # key -> true (don't hammer the API for unknown cards)
var _queue: Array[String] = []  # keys waiting to be requested
var _cooldown: float = 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func _process(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0 and not _queue.is_empty():
		_start_request(_queue.pop_front())
		_cooldown = REQUEST_INTERVAL


## callback(texture: Texture2D) — texture is null when the image is unavailable.
func fetch(card_name: String, callback: Callable) -> void:
	var key := _key(card_name)

	if _cache.has(key):
		callback.call(_cache[key])
		return
	if _failed.has(key):
		callback.call(null)
		return
	if _pending.has(key):
		_pending[key].append(callback)
		return

	var cached := _load_from_disk(key)
	if cached:
		_cache[key] = cached
		callback.call(cached)
		return

	_pending[key] = [callback]
	_queue.append(key)


func _key(card_name: String) -> String:
	return card_name.to_lower().strip_edges()


func _cache_path(key: String) -> String:
	var safe := key.replace(" ", "_").replace("/", "_").replace(",", "").replace("'", "")
	return CACHE_DIR + safe + ".jpg"


func _load_from_disk(key: String) -> Texture2D:
	var path := _cache_path(key)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)


func _start_request(key: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	http.request_completed.connect(_on_request_completed.bind(key, http))
	var url := SCRYFALL_URL % key.uri_encode()
	if http.request(url, _request_headers) != OK:
		push_warning("[CardTextures] request failed to start for '%s'" % key)
		http.queue_free()
		_finish(key, null)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, key: String, http: HTTPRequest) -> void:
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("[CardTextures] could not download '%s' (result %d, HTTP %d)" % [key, result, code])
		_finish(key, null)
		return

	var img := Image.new()
	var err := img.load_jpg_from_buffer(body)
	if err != OK:
		err = img.load_png_from_buffer(body)
	if err != OK:
		push_warning("[CardTextures] unreadable image for '%s'" % key)
		_finish(key, null)
		return

	img.save_jpg(_cache_path(key), 0.9)
	_finish(key, ImageTexture.create_from_image(img))


func _finish(key: String, texture: Texture2D) -> void:
	if texture:
		_cache[key] = texture
	else:
		_failed[key] = true
	if _pending.has(key):
		for cb: Callable in _pending[key]:
			if cb.is_valid():
				cb.call(texture)
		_pending.erase(key)
