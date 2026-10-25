settings.log.stdout.set(true)
settings.log.file.set(false)

# The panel (panel.html + /api/*) is served by this script on panel_port.
# playlist.m3u is the play order; edits from the panel, Notepad or sync-playlist.ps1 apply without a restart.
library = "/music"
radio_dir = "/music/radio"
playlist_file = "#{radio_dir}/playlist.m3u"
state_file = "#{radio_dir}/radio-state.json"
panel_file = "/radio/panel.html"
panel_port = 8001

# Crossfade reads this far ahead to find where a track ends, so every second here is also a second
# listeners hear behind the panel. Liquidsoap's default of 5 s measured ~5.3 s; 1.5 s measures ~1.8 s.
crossfade_seconds = 1.5

tracks = ref([])
upcoming = ref([])
mode = ref("normal")
paused = ref(false)
cursor = ref(0)
on_air = ref(-1)
bag = ref([])
playlist_text = ref("")
library_cache = ref([])
current = ref([])
history = ref([])

def rel(path) =
  string.residual(prefix="#{library}/", path) ?? path
end

def is_audio(path) =
  r/\.(mp3|m4a|ogg|oga|opus|flac|wav|aac)$/i.test(path)
end

def valid(e) =
  e != "" and not string.contains(substring="..", e) and is_audio(e) and file.exists("#{library}/#{e}")
end

# m3u lines are relative to the radio folder: "../Remix/x.mp3" -> "Remix/x.mp3"
def entry_of_line(line) =
  l = string.trim(line)
  if l == "" or string.contains(prefix="#", l) then ""
  elsif string.contains(prefix="#{library}/", l) then rel(l)
  elsif string.contains(prefix="../", l) then string.residual(prefix="../", l) ?? ""
  else "radio/#{l}" end
end

def save_state() =
  file.write(data=json.stringify({mode=mode(), paused=paused(), on_air=on_air(), cursor=cursor()}), state_file)
end

def load_state() =
  if file.exists(state_file) then
    s = json.parse(default={mode="normal", paused=false, on_air=-1, cursor=0}, file.contents(state_file))
    mode := s.mode
    paused := s.paused
    # replay the order track that was cut off by the restart, else carry on where the order was
    cursor := if s.on_air >= 0 then s.on_air else s.cursor end
  end
end

def save_playlist() =
  text = string.concat(separator="\n", "#EXTM3U" :: list.map(fun (e) -> "../#{e}", tracks())) ^ "\n"
  file.write(data=text, playlist_file)
  playlist_text := text
end

def load_playlist() =
  text = if file.exists(playlist_file) then file.contents(playlist_file) else "" end
  playlist_text := text
  tracks := list.filter(valid, list.map(entry_of_line, string.split(separator="\n", text)))
  bag := []
end

def track_request(e, tags) =
  request.create("annotate:#{tags}:#{library}/#{e}")
end

def tag(r, key) =
  m = request.metadata(r)
  m[key]
end

# Bumped by every panel change, so a pick that was resolving meanwhile starts over instead of
# landing a track chosen under the old state.
version = ref(0)
def touch() =
  version := version() + 1
end

# Each pick is tagged with where it came from, so give_back() can undo it once it is queued.
# The pick is only taken (queue popped, cursor moved) after the file resolved under an unchanged state.
def rec pick() =
  v = version()
  n = list.length(tracks())
  from_next = list.length(upcoming()) > 0
  if not from_next and n == 0 then null()
  else
    i =
      if from_next then -1
      elsif mode() == "random" then random.int(min=0, max=n)
      elsif mode() == "randomize" then
        if list.length(bag()) == 0 then bag := list.shuffle(list.init(n, fun (i) -> i)) end
        list.hd(bag())
      else cursor() mod n end
    e = if from_next then list.hd(upcoming()) else list.nth(tracks(), i) end
    r = track_request(e, if from_next then "radio_from=\"next\"" else "radio_from=\"#{mode()}\",radio_index=\"#{i}\"" end)
    ok = request.resolve(r)
    if version() != v then pick()
    else
      if from_next then upcoming := list.tl(upcoming())
      elsif mode() == "randomize" then bag := list.tl(bag())
      elsif mode() == "normal" then cursor := i + 1 end
      if ok then null(r) else null() end
    end
  end
end

load_state()
load_playlist()

#   upcoming ("play next") ─┐
#                           ├─ pick() ─> auto [1 prefetched] ─> pause switch ─> crossfade ─> icecast
#   tracks + mode + cursor ─┘
# The pause switch sits before crossfade so crossfade is never starved (it wedges if left mid-transition);
# pausing fades out to silence and leaves auto unread, so resuming continues the same track.
auto = request.dynamic(id="auto", retry_delay=2., pick)
auto.on_track(fun (m) -> begin
  current := m
  on_air := int_of_string(m["radio_index"], default=-1)
  save_state()
  history := list.prefix(12, {file=rel(m["filename"]), title=m["title"], artist=m["artist"], at=time()} :: history())
end)
music = switch(id="music", track_sensitive=false, [({not paused()}, auto), ({true}, blank(id="paused"))])
radio = crossfade(duration=crossfade_seconds, fade_in=crossfade_seconds, fade_out=crossfade_seconds, music)

# After the order changes, carry on after the track that is on air (if it is still in the list).
def follow_on_air() =
  m = current()
  f = rel(m["filename"])
  list.iteri(fun (i, e) -> if e == f then cursor := i + 1 end, tracks())
  bag := []
end

# The prefetched request was picked under the old state: give back what it took (queue slot, cursor step,
# shuffle slot). Callers: touch(), give_back(), change state, touch(), auto.set_queue(...) - the touches
# make a pick that is resolving meanwhile start over under the new state.
def give_back(~keep_next=true, ~list_changed=false) =
  list.iter(fun (r) -> begin
    from = tag(r, "radio_from")
    i = int_of_string(tag(r, "radio_index"), default=-1)
    if from == "next" then
      if keep_next then upcoming := rel(request.filename(r)) :: upcoming() end
    elsif not list_changed and i >= 0 then
      if from == "normal" then cursor := i end
      if from == "randomize" then bag := i :: bag() end
    end
  end, list.rev(auto.queue()))
  if list_changed then follow_on_air() end
end

# reload only once two reads agree, so a file caught mid-write is never loaded
seen = ref("")
thread.run(every=5., fun () -> begin
  text = if file.exists(playlist_file) then file.contents(playlist_file) else "" end
  stable = text == seen()
  seen := text
  if stable and text != playlist_text() then
    log.important("playlist.m3u changed on disk, reloading")
    touch()
    load_playlist()
    give_back(list_changed=true)
    touch()
    auto.set_queue([])
  end
end)

def scan_library() =
  files = file.ls(absolute=true, recursive=true, sorted=true, library)
  library_cache := list.filter(fun (e) -> is_audio(e) and not string.contains(substring="/.", e), list.map(rel, files))
end

def status() =
  m = current()
  queued = auto.queue()
  next_up = list.filter(fun (r) -> tag(r, "radio_from") == "next", queued)
  next_rows = list.map(fun (r) -> int_of_string(tag(r, "radio_index"), default=-1), queued)
  {
    mode = mode(),
    paused = paused(),
    next_index = list.hd(default=-1, next_rows),
    now = {
      file = rel(m["filename"]),
      title = m["title"],
      artist = m["artist"],
      elapsed = auto.elapsed(),
      duration = auto.duration()
    },
    tracks = tracks(),
    queue = list.append(list.map(fun (r) -> rel(request.filename(r)), next_up), upcoming())
  }
end

def api(path, handler) =
  harbor.http.register(port=panel_port, method="POST", "/api/#{path}", fun (req, res) -> begin
    try
      handler(req.body(timeout=5.))
      res.json(status())
    catch err do
      log.important("panel #{path}: #{err.message}")
      res.status_code(400)
      res.json({error=err.message})
    end
  end)
end

harbor.http.register(port=panel_port, method="GET", "/", fun (_, res) -> res.html(file.contents(panel_file)))
harbor.http.register(port=panel_port, method="GET", "/api/status", fun (_, res) -> res.json(status()))
# Read-only data for the listener page (port 8000 proxies only /api/now and /api/cover).
# history[0] is the track being read now; listeners hear it a few seconds later.
def public_now() =
  m = current()
  queued = auto.queue()
  nxt =
    if list.length(queued) > 0 then
      r = list.hd(queued)
      md = request.metadata(r)
      {file=rel(request.filename(r)), title=md["title"], artist=md["artist"]}
    elsif list.length(upcoming()) > 0 then {file=list.hd(upcoming()), title="", artist=""}
    else {file="", title="", artist=""} end
  {
    paused = paused(),
    time = time(),
    now = {file=rel(m["filename"]), title=m["title"], artist=m["artist"], elapsed=auto.elapsed(), duration=auto.duration()},
    next = nxt,
    history = history()
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/now", fun (_, res) -> res.json(public_now()))

harbor.http.register(port=panel_port, method="GET", "/api/cover", fun (req, res) -> begin
  f = req.query["f"]
  c = if valid(f) then file.cover("#{library}/#{f}") else null() end
  if null.defined(c) then
    cv = null.get(c)
    res.content_type(cv.mime)
    res.header("Cache-Control", "public, max-age=604800")
    res.data((cv : string))
  else
    res.status_code(404)
    res.data("")
  end
end)

harbor.http.register(port=panel_port, method="GET", "/api/library", fun (req, res) -> begin
  if req.query["refresh"] != "" or list.length(library_cache()) == 0 then scan_library() end
  res.json(library_cache())
end)

api("skip", fun (_) -> begin
  paused := false
  save_state()
  auto.skip()
end)

api("pause", fun (body) -> begin
  let json.parse (p : {paused: bool}) = body
  paused := p.paused
  save_state()
end)

api("mode", fun (body) -> begin
  let json.parse (p : {mode: string}) = body
  if list.mem(p.mode, ["normal", "randomize", "random"]) then
    touch()
    give_back()
    mode := p.mode
    bag := []
    save_state()
    touch()
    auto.set_queue([])
  end
end)

# Rows already in the list always pass (even if the file has since gone); anything else must be a real
# file, otherwise the whole change is refused instead of silently dropping rows.
api("tracks", fun (body) -> begin
  let json.parse (p : {tracks: [string]}) = body
  unknown = list.filter(fun (e) -> not list.mem(e, tracks()) and not valid(e), p.tracks)
  if list.length(unknown) > 0 then
    error.raise(error.register("panel"), "unknown track: #{list.hd(unknown)}")
  end
  touch()
  tracks := p.tracks
  save_playlist()
  give_back(list_changed=true)
  touch()
  auto.set_queue([])
end)

# index >= 0 is a row of the play order: the order carries on after it
api("play", fun (body) -> begin
  let json.parse (p : {file: string, index: int}) = body
  if valid(p.file) then
    r = track_request(p.file, "radio_from=\"play\",radio_index=\"#{p.index}\"")
    if request.resolve(r) then
      touch()
      give_back()
      if p.index >= 0 and mode() == "normal" then cursor := p.index + 1 end
      paused := false
      save_state()
      touch()
      auto.set_queue([r])
      auto.skip()
    end
  end
end)

api("next", fun (body) -> begin
  let json.parse (p : {file: string}) = body
  if valid(p.file) then
    touch()
    give_back()
    upcoming := list.append(upcoming(), [p.file])
    touch()
    auto.set_queue([])
  end
end)

api("queue/clear", fun (_) -> begin
  touch()
  give_back(keep_next=false)
  upcoming := []
  touch()
  auto.set_queue([])
end)

output.icecast(
  %mp3(bitrate=192),
  host="icecast",
  port=8000,
  password=environment.get("ICECAST_SOURCE_PASSWORD"),
  mount="/radio",
  name="LAN Radio",
  description="Music from the local network",
  genre="Mixed",
  mksafe(radio)
)
