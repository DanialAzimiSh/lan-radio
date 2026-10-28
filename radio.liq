settings.log.stdout.set(true)
settings.log.file.set(false)

# The panel (the panel/ folder + /api/*) is served by this script on panel_port.
# playlist.m3u is the play order; edits from the panel, Notepad or sync-playlist.ps1 apply without a restart.
library = "/music"
radio_dir = "/music/radio"
playlist_file = "#{radio_dir}/playlist.m3u"
state_file = "#{radio_dir}/radio-state.json"
panel_dir = "/radio/panel"
panel_port = 8001

# Tracks listed in hidden.txt (paths relative to the music folder) never show their name, tags or cover
# to listeners - not on the listener page, not in VLC/phone players, not in Icecast's status. The admin
# panel still shows everything. This is what listeners see instead:
hidden_file = "#{radio_dir}/hidden.txt"
hidden_title = "موسیقی"

# Crossfade reads this far ahead to find where a track ends, so every second here is also a second
# listeners hear behind the panel. Liquidsoap's default of 5 s measured ~5.3 s; 1.5 s measures ~1.8 s.
crossfade_seconds = 1.5

# Live input on :8005/live (see "Live input" below). Its buffer is also delay for listeners.
live_port = 8005
live_buffer_seconds = 1.

# The admin panel asks for PANEL_PASSWORD (.env); a login lasts 30 days and survives restarts.
panel_password = environment.get("PANEL_PASSWORD")
session_seconds = 30 * 24 * 3600

# SQLite (sessions, likes) lives on a Docker volume, not in the music folder: SQLite's file locking
# is unreliable on Windows bind mounts. The volume sits on the liquidsoap user's home, which the image
# already gives that user (a fresh volume elsewhere belongs to root and the database can't be created).
db_file = "/var/cache/liquidsoap/radio.db"

tracks = ref([])
upcoming = ref([])
mode = ref("normal")
paused = ref(false)
cursor = ref(0)
on_air = ref(-1)
bag = ref([])
playlist_text = ref("")
library_cache = ref([])
library_scanned = ref(0.)
current = ref([])
history = ref([])
hidden = ref([])
hidden_text = ref("")
play_seq = ref(0)
sessions = ref([])
login_failures = ref([])

def rel(path) =
  string.residual(prefix="#{library}/", path) ?? path
end

def is_audio(path) =
  r/\.(mp3|m4a|ogg|oga|opus|flac|wav|aac)$/i.test(path)
end

def valid(e) =
  e != "" and not string.contains(substring="..", e) and is_audio(e) and file.exists("#{library}/#{e}")
end

# ---------- database ----------
# Schema changes are appended to `migrations`, never edited: each runs once, in order, and
# PRAGMA user_version records how many have run. Every write is one statement (e.g. INSERT OR IGNORE),
# so concurrent HTTP handlers need no lock beyond SQLite's own.
db = sqlite(db_file)

# a column by name: SQLite rows come back with their columns in no particular order
def col(row, name) =
  v = ref("")
  list.iter(fun (kv) -> if fst(kv) == name then v := snd(kv) ?? "" end, row.to_list())
  v()
end

def db_int(sql, name) =
  rows = db.query(sql)
  if list.length(rows) == 0 then 0 else int_of_string(col(list.hd(rows), name), default=0) end
end

migrations = [
  "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
  "CREATE TABLE sessions (token TEXT PRIMARY KEY, created REAL NOT NULL)",
  "CREATE TABLE likes (track TEXT NOT NULL, listener TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY (track, listener))",
  "CREATE TABLE reactions (id INTEGER PRIMARY KEY AUTOINCREMENT, track TEXT NOT NULL, listener TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL)",
  "CREATE INDEX reactions_track ON reactions (track)",
  "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, listener TEXT NOT NULL, name TEXT NOT NULL, body TEXT NOT NULL, track TEXT NOT NULL, title TEXT NOT NULL, at REAL NOT NULL, is_read INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE requests (id INTEGER PRIMARY KEY AUTOINCREMENT, listener TEXT NOT NULL, name TEXT NOT NULL, file TEXT NOT NULL, body TEXT NOT NULL, at REAL NOT NULL, status TEXT NOT NULL, done_at REAL NOT NULL DEFAULT 0)",
  "CREATE INDEX requests_file ON requests (file)",
  "CREATE TABLE uploads (id INTEGER PRIMARY KEY AUTOINCREMENT, listener TEXT NOT NULL, name TEXT NOT NULL, orig TEXT NOT NULL, stored TEXT NOT NULL, size INTEGER NOT NULL, secs REAL NOT NULL, at REAL NOT NULL, status TEXT NOT NULL, dest TEXT NOT NULL DEFAULT '')"
]
schema_version = db_int("PRAGMA user_version", "user_version")
list.iteri(fun (i, sql) -> if i >= schema_version then begin
  log.important("database: migration #{i + 1}")
  db.exec(sql)
  db.exec("PRAGMA user_version = #{i + 1}")
end end, migrations)

# ---------- admin login ----------
# A changed PANEL_PASSWORD logs every browser out; expired logins are dropped at start.
def load_sessions() =
  fingerprint = string.digest(panel_password)
  stored = db.query("SELECT value FROM meta WHERE key = 'password'")
  if list.length(stored) == 0 or col(list.hd(stored), "value") != fingerprint then
    db.exec("DELETE FROM sessions")
    db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('password', #{sqlite.escape(fingerprint)})")
  end
  db.exec("DELETE FROM sessions WHERE created < #{time() - float_of_int(session_seconds)}")
  sessions := list.map(fun (r) -> col(r, "token"), db.query("SELECT token FROM sessions"))
end
load_sessions()

def cookie(req, name) =
  v = ref("")
  list.iter(fun (h) -> if string.case(lower=true, fst(h)) == "cookie" then
    list.iter(fun (kv) -> begin
      parts = string.split(separator="=", string.trim(kv))
      if list.length(parts) == 2 and list.hd(parts) == name then v := list.nth(parts, 1) end
    end, string.split(separator=";", snd(h)))
  end, req.headers)
  v()
end

def signed_in(req) =
  t = cookie(req, "radio_session")
  t != "" and list.mem(t, sessions())
end

def random_token() =
  string.trim(process.read("head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \\n'"))
end

# ---------- likes ----------
# Listeners like a play (its id in the history), never a file name: hidden tracks stay nameless.
def valid_listener(l) =
  r/^[A-Za-z0-9-]{8,64}$/.test(l)
end

def like_count(file) =
  db_int("SELECT COUNT(*) AS n FROM likes WHERE track = #{sqlite.escape(file)}", "n")
end

def liked_by(listener, file) =
  listener != "" and db_int("SELECT COUNT(*) AS n FROM likes WHERE track = #{sqlite.escape(file)} AND listener = #{sqlite.escape(listener)}", "n") > 0
end

def all_like_counts() =
  list.map(fun (r) -> {file=col(r, "track"), n=int_of_string(col(r, "n"), default=0)},
    db.query("SELECT track, COUNT(*) AS n FROM likes GROUP BY track ORDER BY n DESC"))
end

# ---------- reactions and messages ----------
# Reactions are quick emoji taps on the track on air. Two separate things happen to a tap:
#  - it is stored in SQLite per file (for the admin's numbers), but only up to reaction_cap per
#    listener, kind and file; taps past the cap are not stored;
#  - it bumps `live_taps`, an in-memory tally for the play on air that starts again at zero with every
#    play and counts every tap, capped or not. Listeners never see numbers: the page animates the
#    tally's growth, which is how everyone sees everyone else's reactions.
# Messages are private notes to the admin: listeners never see them, so a message can't give a hidden
# track away.
reaction_kinds = ["fire", "clap", "wow", "sleep"]
reaction_cap = 50
live_play = ref(-1)
live_tally = ref({fire=0, clap=0, wow=0, sleep=0})

def live_taps(id) =
  if live_play() != id then
    live_play := id
    live_tally := {fire=0, clap=0, wow=0, sleep=0}
  end
  live_tally()
end

def tap_live(id, kind) =
  t = live_taps(id)
  def up(k, v) =
    if kind == k then v + 1 else v end
  end
  live_tally := {fire=up("fire", t.fire), clap=up("clap", t.clap), wow=up("wow", t.wow), sleep=up("sleep", t.sleep)}
end
message_max = 280
name_max = 30

# ---------- song requests and uploads ----------
# A request is a listener asking for a library track (or, when it isn't in the library, naming a song).
# The admin accepts it (manual mode, the default) or it goes straight to "play next" (auto mode, a switch
# in the panel). An upload is a listener sending a file: it lands in a quarantine folder that is not part
# of the library, and only joins the library once the admin approves it. Every number here is a brake.
request_gap = 600.
request_pending_max = 60
request_text_max = 120
upload_dir = "#{radio_dir}/.incoming"
upload_dest = "Uploads"
upload_max_bytes = 30 * 1024 * 1024
upload_quota_bytes = 500 * 1024 * 1024
upload_pending_max = 20
upload_gap = 900.
upload_max_seconds = 900.
upload_keep_seconds = 7. * 24. * 3600.

def reaction_counts(file) =
  rows = db.query("SELECT kind, COUNT(*) AS n FROM reactions WHERE track = #{sqlite.escape(file)} GROUP BY kind")
  def n(k) =
    v = ref(0)
    list.iter(fun (r) -> if col(r, "kind") == k then v := int_of_string(col(r, "n"), default=0) end, rows)
    v()
  end
  {fire=n("fire"), clap=n("clap"), wow=n("wow"), sleep=n("sleep")}
end

def messages_json() =
  rows = db.query("SELECT id, name, body, title, at, is_read FROM messages ORDER BY id DESC LIMIT 200")
  {
    unread = db_int("SELECT COUNT(*) AS n FROM messages WHERE is_read = 0", "n"),
    time = time(),
    items = list.map(fun (r) -> {
      id = int_of_string(col(r, "id"), default=0),
      name = col(r, "name"),
      text = col(r, "body"),
      title = col(r, "title"),
      at = float_of_string(col(r, "at")),
      read = col(r, "is_read") == "1"
    }, rows)
  }
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

def load_hidden() =
  text = if file.exists(hidden_file) then file.contents(hidden_file) else "" end
  hidden_text := text
  lines = list.map(string.trim, string.split(separator="\n", text))
  hidden := list.filter(fun (l) -> l != "" and not string.contains(prefix="#", l), lines)
end

def save_hidden() =
  header = "# Hidden from listeners (name, tags, cover). One path per line, relative to the music folder."
  text = string.concat(separator="\n", header :: hidden()) ^ "\n"
  file.write(data=text, hidden_file)
  hidden_text := text
end

def is_hidden(f) =
  f != "" and list.mem(f, hidden())
end

load_hidden()

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
#                           ├─ pick() ─> auto [1 prefetched] ─┐
#   tracks + mode + cursor ─┘                                 ├─ live switch ─> pause switch ─> crossfade ─> icecast
#                                    live (:8005/live) ───────┘
# Both switches sit before crossfade so crossfade is never starved (it wedges if left mid-transition);
# pausing or going live fades over and leaves auto unread, so the music resumes the same track.
auto = request.dynamic(id="auto", retry_delay=2., pick)
auto.on_track(fun (m) -> begin
  current := m
  on_air := int_of_string(m["radio_index"], default=-1)
  save_state()
  play_seq := play_seq() + 1
  history := list.prefix(12, {id=play_seq(), file=rel(m["filename"]), title=m["title"], artist=m["artist"], at=time()} :: history())
  aired = rel(m["filename"])
  db.exec("UPDATE requests SET status = 'played', done_at = #{time()} WHERE status = 'queued' AND file = #{sqlite.escape(aired)}")
end)
# Live input: while a source is connected to :8005/live it replaces the music. Sources: the panel's
# «پخش زنده» (browser, WebSocket "webcast" protocol, a one-time password from /api/live/token in its hello
# message) or any Icecast-protocol app (BUTT, Mixxx, ffmpeg; user "source", password LIVE_PASSWORD).
# There is no kick: live.stop() and the "live.stop" command leave the harbor refusing every later source
# until a restart. Turning live_allowed off takes the source off the air and refuses new connections;
# an unaired source keeps ~1 s buffered, so turning it back on is still near-live.
live_password = environment.get("LIVE_PASSWORD")
live_allowed = ref(true)
live_connected = ref(false)
live_since = ref(0.)
live_title = ref("")
live_client = ref("")
live_tokens = ref([])

def live_auth(c) =
  token = list.mem(c.password, live_tokens())
  live_tokens := list.filter(fun (t) -> t != c.password, live_tokens())
  live_allowed() and c.password != "" and (c.password == live_password or token)
end

# one-time password for the panel's browser source, so LIVE_PASSWORD never reaches a browser
def live_token() =
  t = "#{random.int(min=100000000, max=999999999)}#{random.int(min=100000000, max=999999999)}"
  live_tokens := t :: list.prefix(4, live_tokens())
  thread.run(delay=120., fun () -> live_tokens := list.filter(fun (x) -> x != t, live_tokens()))
  t
end

live = input.harbor(id="live", "live", port=live_port, auth=live_auth,
  buffer=live_buffer_seconds, max=live_buffer_seconds + 2.,
  on_connect=fun (h) -> begin
    live_connected := true
    live_since := time()
    live_title := ""
    live_client := h["User-Agent"]
  end,
  on_disconnect=fun () -> begin
    live_connected := false
    live_title := ""
  end)
live.on_metadata(fun (m) -> if m["title"] != "" then live_title := m["title"] end)

# The harbor input is an active source: its own clock drains it in real time even when it is off the air.
# Read straight from the crossfade chain it was drained twice as fast and the switch flapped live <-> music
# every couple of seconds; buffer() gives it a clock of its own and hands the chain a buffer instead.
# The buffer must also cover what crossfade takes at once when live comes on.
live_feed = buffer(id="live_feed", buffer=crossfade_seconds + 0.5, max=crossfade_seconds + 3., live)

def live_airing() =
  live_connected() and live_allowed() and not paused() and live_feed.is_ready()
end

def live_seconds() =
  if live_connected() then time() - live_since() else 0. end
end

def live_status() =
  {
    allowed = live_allowed(),
    connected = live_connected(),
    airing = live_airing(),
    since = live_seconds(),
    title = live_title(),
    client = live_client(),
    buffer = live.buffer_length(),
    port = live_port
  }
end

on_air_source = switch(id="source", track_sensitive=false, [({live_allowed()}, live_feed), ({true}, auto)])
music = switch(id="music", track_sensitive=false, [({not paused()}, on_air_source), ({true}, blank(id="paused"))])
radio = crossfade(duration=crossfade_seconds, fade_in=crossfade_seconds, fade_out=crossfade_seconds, music)

# VLC, phone players and Icecast's status page read the stream's own metadata: a hidden track goes out
# with every tag cleared (update=false) and only hidden_title left. Metadata is only sent when a track
# starts, so hiding or showing the track on air re-sends it through meta_in (see the "hidden" API).
def outgoing_metadata(m) =
  if is_hidden(rel(m["filename"])) then [("title", hidden_title)] else m end
end
meta_in = insert_metadata(radio)
radio = metadata.map(update=false, outgoing_metadata, meta_in)

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
seen_hidden = ref("")
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
  h = if file.exists(hidden_file) then file.contents(hidden_file) else "" end
  stable_h = h == seen_hidden()
  seen_hidden := h
  if stable_h and h != hidden_text() then
    log.important("hidden.txt changed on disk, reloading")
    load_hidden()
  end
end)

def scan_library() =
  library_scanned := time()
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
    queue = list.append(list.map(fun (r) -> rel(request.filename(r)), next_up), upcoming()),
    live = live_status(),
    hidden = hidden(),
    hidden_title = hidden_title,
    likes = all_like_counts(),
    reactions = reaction_counts(rel(m["filename"])),
    messages_unread = db_int("SELECT COUNT(*) AS n FROM messages WHERE is_read = 0", "n"),
    requests_pending = db_int("SELECT COUNT(*) AS n FROM requests WHERE status = 'pending'", "n"),
    uploads_pending = db_int("SELECT COUNT(*) AS n FROM uploads WHERE status = 'pending'", "n")
  }
end

# Every admin endpoint goes through here. The page itself (GET /) is public: it holds no data and shows
# the login form when /api/status answers 401. Public endpoints: /api/now, /api/cover, /api/like, /api/login.
# (res.data, not res.json: a res passed into a function gets one fixed json type, clashing with the caller's)
def admin(req, res, f) =
  if signed_in(req) then f()
  else
    res.status_code(401)
    res.content_type("application/json")
    res.data("{\"error\": \"login\"}")
  end
end

def api(path, handler) =
  harbor.http.register(port=panel_port, method="POST", "/api/#{path}", fun (req, res) -> admin(req, res, fun () -> begin
    try
      handler(req.body(timeout=5.))
      res.json(status())
    catch err do
      log.important("panel #{path}: #{err.message}")
      res.status_code(400)
      res.json({error=err.message})
    end
  end))
end

harbor.http.register(port=panel_port, method="GET", "/", fun (_, res) -> res.html(file.contents("#{panel_dir}/index.html")))
# The panel's own files (css, js, Alpine) hold no data, so like the page itself they need no login.
def panel_type(f) =
  if r/\.js$/.test(f) then "text/javascript; charset=utf-8"
  elsif r/\.css$/.test(f) then "text/css; charset=utf-8"
  elsif r/\.svg$/.test(f) then "image/svg+xml"
  else null() end
end
harbor.http.static(port=panel_port, path="/panel", content_type=panel_type, headers=[("Cache-Control", "no-cache")], panel_dir)
harbor.http.register(port=panel_port, method="GET", "/api/status", fun (req, res) -> admin(req, res, fun () -> res.json(status())))

# 5 wrong passwords within a minute lock the form for the rest of that minute (one shared counter:
# behind Docker Desktop every browser arrives from the same address).
harbor.http.register(port=panel_port, method="POST", "/api/login", fun (req, res) -> begin
  now = time()
  login_failures := list.filter(fun (t) -> now - t < 60., login_failures())
  if list.length(login_failures()) >= 5 then
    res.status_code(429)
    res.json({error="تلاش زیاد شد؛ یک دقیقه صبر کن"})
  else
    password = try
      let json.parse (p : {password: string}) = req.body(timeout=5.)
      p.password
    catch _ do "" end
    if panel_password != "" and password == panel_password then
      t = random_token()
      db.exec("INSERT INTO sessions (token, created) VALUES (#{sqlite.escape(t)}, #{now})")
      sessions := t :: sessions()
      res.header("Set-Cookie", "radio_session=#{t}; Path=/; HttpOnly; SameSite=Strict; Max-Age=#{session_seconds}")
      res.json({ok=true})
    else
      login_failures := now :: login_failures()
      res.status_code(401)
      res.json({error="رمز درست نیست"})
    end
  end
end)

harbor.http.register(port=panel_port, method="POST", "/api/logout", fun (req, res) -> begin
  t = cookie(req, "radio_session")
  db.exec("DELETE FROM sessions WHERE token = #{sqlite.escape(t)}")
  sessions := list.filter(fun (x) -> x != t, sessions())
  res.header("Set-Cookie", "radio_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
  res.json({ok=true})
end)
# Read-only data for the listener page (port 8000 proxies only /api/now and /api/cover).
# history[0] is the track being read now; listeners hear it a few seconds later.
# A hidden track leaves no trace here: no path (file names give titles away), no tags, no cover.
# Whether listeners may search the library when they request a song. Off (the default), the page only
# lets them write a name for the admin, so nobody can browse what the station owns.
def catalog_public() =
  rows = db.query("SELECT value FROM meta WHERE key = 'catalog_public'")
  list.length(rows) > 0 and col(list.hd(rows), "value") == "1"
end

# "Persian/Artist - Song.mp3" -> "Artist - Song"
def label_of(file) =
  parts = string.split(separator="/", file)
  r/\.[A-Za-z0-9]+$/.replace(fun (_) -> "", list.hd(default=file, list.rev(parts)))
end

# the listener's own recent requests, so the page can show where each one stands
def mine_requests(listener) =
  if listener == "" then []
  else
    since = time() - 600.
    rows = db.query("SELECT id, file, body, status FROM requests WHERE listener = #{sqlite.escape(listener)} AND (status IN ('pending', 'queued') OR done_at > #{since}) ORDER BY id DESC LIMIT 5")
    list.map(fun (r) -> begin
      f = col(r, "file")
      {id=int_of_string(col(r, "id"), default=0), label=(if f != "" then label_of(f) else col(r, "body") end), status=col(r, "status")}
    end, rows)
  end
end

def public_track(file, title, artist) =
  if is_hidden(file) then {file="", title=hidden_title, artist=""}
  else {file=file, title=title, artist=artist} end
end

# `listener` is the anonymous id the listener page keeps in the browser; it only marks the listener's own likes.
def public_now(listener) =
  m = current()
  queued = auto.queue()
  nxt =
    if list.length(queued) > 0 then
      r = list.hd(queued)
      md = request.metadata(r)
      public_track(rel(request.filename(r)), md["title"], md["artist"])
    elsif list.length(upcoming()) > 0 then public_track(list.hd(upcoming()), "", "")
    else {file="", title="", artist=""} end
  n = public_track(rel(m["filename"]), m["title"], m["artist"])
  plays = list.map(fun (h) -> begin
    p = public_track(h.file, h.title, h.artist)
    {id=h.id, file=p.file, title=p.title, artist=p.artist, at=h.at, likes=like_count(h.file), liked=liked_by(listener, h.file)}
  end, history())
  # history[0] is the track on air (unless nothing has played yet)
  on = list.hd(default={id=-1, file="", title="", artist="", at=0., likes=0, liked=false}, plays)
  {
    paused = paused(),
    time = time(),
    now = {id=on.id, file=n.file, title=n.title, artist=n.artist, elapsed=auto.elapsed(), duration=auto.duration(), likes=on.likes, liked=on.liked, reactions=live_taps(on.id)},
    mine = mine_requests(listener),
    catalog_open = catalog_public(),
    next = nxt,
    history = plays,
    live = {airing=live_airing(), title=live_title(), since=live_seconds()}
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/now", fun (req, res) -> begin
  l = req.query["listener"]
  res.json(public_now(if valid_listener(l) then l else "" end))
end)

# {play, listener, liked}: play is an id from /api/now's history, so only the last 12 plays can be liked
harbor.http.register(port=panel_port, method="POST", "/api/like", fun (req, res) -> begin
  try
    let json.parse (p : {play: int, listener: string, liked: bool}) = req.body(timeout=5.)
    plays = list.filter(fun (h) -> h.id == p.play, history())
    if not valid_listener(p.listener) or list.length(plays) == 0 then
      res.status_code(400)
      res.json({error="unknown play or listener"})
    else
      h = list.hd(plays)
      f = sqlite.escape(h.file)
      l = sqlite.escape(p.listener)
      if p.liked then db.exec("INSERT OR IGNORE INTO likes (track, listener, at) VALUES (#{f}, #{l}, #{time()})")
      else db.exec("DELETE FROM likes WHERE track = #{f} AND listener = #{l}") end
      res.json({play=p.play, likes=like_count(h.file), liked=p.liked})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

# {play, listener, kind}: like /api/like, `play` is an id from /api/now; answers with the file's counts
harbor.http.register(port=panel_port, method="POST", "/api/react", fun (req, res) -> begin
  try
    let json.parse (p : {play: int, listener: string, kind: string}) = req.body(timeout=5.)
    plays = list.filter(fun (h) -> h.id == p.play, history())
    if not valid_listener(p.listener) or list.length(plays) == 0 or not list.mem(p.kind, reaction_kinds) then
      res.status_code(400)
      res.json({error="unknown play, listener or reaction"})
    else
      h = list.hd(plays)
      f = sqlite.escape(h.file)
      l = sqlite.escape(p.listener)
      k = sqlite.escape(p.kind)
      mine = db_int("SELECT COUNT(*) AS n FROM reactions WHERE track = #{f} AND listener = #{l} AND kind = #{k}", "n")
      if mine < reaction_cap then db.exec("INSERT INTO reactions (track, listener, kind, at) VALUES (#{f}, #{l}, #{k}, #{time()})") end
      # a tap that arrives after the track changed is stored but no longer animates for anyone
      cur = list.hd(default={id=-1, file="", title="", artist="", at=0.}, history())
      if cur.id == p.play then tap_live(p.play, p.kind) end
      res.json({play=cur.id, reactions=live_taps(cur.id)})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

# {play, listener, name, text}: one message per listener per 30 s, 20 per minute overall (listener ids are
# only a browser-side random string, so the overall cap is the real brake). Stored with what was on air.
harbor.http.register(port=panel_port, method="POST", "/api/message", fun (req, res) -> begin
  try
    let json.parse (p : {play: int, listener: string, name: string, text: string}) = req.body(timeout=5.)
    text = string.trim(p.text)
    name = string.trim(p.name)
    now = time()
    l = sqlite.escape(p.listener)
    too_soon = db_int("SELECT COUNT(*) AS n FROM messages WHERE listener = #{l} AND at > #{now - 30.}", "n") > 0
    too_many = db_int("SELECT COUNT(*) AS n FROM messages WHERE at > #{now - 60.}", "n") >= 20
    if not valid_listener(p.listener) or text == "" or string.length(text) > message_max or string.length(name) > name_max then
      res.status_code(400)
      res.json({error="پیام خالی است یا بلندتر از حد مجاز"})
    elsif too_soon or too_many then
      res.status_code(429)
      res.json({error="چند لحظه صبر کن و دوباره بفرست"})
    else
      h = list.hd(default={id=-1, file="", title="", artist="", at=0.}, list.filter(fun (x) -> x.id == p.play, history()))
      live_now = live_airing()
      label =
        if live_now then "🎙 پخش زنده"
        elsif h.title != "" and h.artist != "" then "#{h.artist} - #{h.title}"
        elsif h.title != "" then h.title
        else h.file end
      file = if live_now then "" else h.file end
      db.exec("INSERT INTO messages (listener, name, body, track, title, at) VALUES (#{l}, #{sqlite.escape(name)}, #{sqlite.escape(text)}, #{sqlite.escape(file)}, #{sqlite.escape(label)}, #{now})")
      res.json({ok=true})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

harbor.http.register(port=panel_port, method="GET", "/api/cover", fun (req, res) -> begin
  f = req.query["f"]
  c = if valid(f) and not is_hidden(f) then file.cover("#{library}/#{f}") else null() end
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

# Inbox: GET lists the newest 200; read/delete take {id}, where id 0 means "all unread" / "all already read"
harbor.http.register(port=panel_port, method="GET", "/api/messages", fun (req, res) -> admin(req, res, fun () -> res.json(messages_json())))

harbor.http.register(port=panel_port, method="POST", "/api/messages/read", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    db.exec(if p.id > 0 then "UPDATE messages SET is_read = 1 WHERE id = #{p.id}" else "UPDATE messages SET is_read = 1" end)
    res.json(messages_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/messages/delete", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    db.exec(if p.id > 0 then "DELETE FROM messages WHERE id = #{p.id}" else "DELETE FROM messages WHERE is_read = 1" end)
    res.json(messages_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# ---------- song requests ----------
# `file` is a library path for a track request, "" for a "this song isn't in your library" note (then `body`).
# Status: pending -> queued (in "play next") -> played, or rejected; a note ends as done or rejected.
def play_next(file) =
  touch()
  give_back()
  upcoming := list.append(upcoming(), [file])
  touch()
  auto.set_queue([])
end

# every track already lined up: the prefetched one and the rest of "play next"
def queued_files() =
  next_up = list.filter(fun (r) -> tag(r, "radio_from") == "next", auto.queue())
  list.append(list.map(fun (r) -> rel(request.filename(r)), next_up), upcoming())
end

def request_mode() =
  rows = db.query("SELECT value FROM meta WHERE key = 'request_mode'")
  if list.length(rows) > 0 and col(list.hd(rows), "value") == "auto" then "auto" else "manual" end
end

# what a listener can ask for: the library minus hidden tracks and the radio folder's own files
def catalog_all() =
  if list.length(library_cache()) == 0 or time() - library_scanned() > 300. then scan_library() end
  uploads_prefix = "radio/#{upload_dest}/"
  list.filter(fun (f) -> begin
    own = string.contains(prefix="radio/", f) and not string.contains(prefix=uploads_prefix, f)
    not is_hidden(f) and not own
  end, library_cache())
end

def catalog() =
  if not catalog_public() then [] else catalog_all() end
end

harbor.http.register(port=panel_port, method="GET", "/api/catalog", fun (req, res) -> begin
  res.header("Cache-Control", "public, max-age=60")
  res.json(catalog())
end)

# {listener, name, file, text}: either file (from /api/catalog) or text. 10 minutes between a listener's requests.
harbor.http.register(port=panel_port, method="POST", "/api/request", fun (req, res) -> begin
  try
    let json.parse (p : {listener: string, name: string, file: string, text: string}) = req.body(timeout=5.)
    now = time()
    l = sqlite.escape(p.listener)
    name = string.trim(p.name)
    text = string.trim(p.text)
    wanted = p.file
    by_file = wanted != ""
    bad_text = string.length(text) > request_text_max or (not by_file and text == "") or (by_file and text != "")
    unknown = by_file and (not valid(wanted) or is_hidden(wanted))
    closed = by_file and not catalog_public()
    too_soon = db_int("SELECT COUNT(*) AS n FROM requests WHERE listener = #{l} AND at > #{now - request_gap}", "n") > 0
    too_many = db_int("SELECT COUNT(*) AS n FROM requests WHERE status = 'pending'", "n") >= request_pending_max
    f = sqlite.escape(wanted)
    again = by_file and db_int("SELECT COUNT(*) AS n FROM requests WHERE listener = #{l} AND file = #{f} AND status IN ('pending', 'queued')", "n") > 0
    on_air_now = by_file and list.length(list.filter(fun (h) -> h.file == wanted, history())) > 0
    in_queue = by_file and list.mem(wanted, queued_files())
    if not valid_listener(p.listener) or bad_text or string.length(name) > name_max then
      res.status_code(400)
      res.json({error="درخواست درست نیست"})
    elsif closed then
      res.status_code(403)
      res.json({error="فهرست آهنگ‌ها فعلاً بسته است؛ اسم آهنگ را بنویس"})
    elsif unknown then
      res.status_code(404)
      res.json({error="این آهنگ پیدا نشد"})
    elsif again then
      res.status_code(409)
      res.json({error="این آهنگ را قبلاً درخواست کرده‌ای"})
    elsif on_air_now or in_queue then
      res.status_code(409)
      res.json({error="این آهنگ همین حالا در صف است یا تازه پخش شده"})
    elsif too_soon then
      res.status_code(429)
      res.json({error="چند دقیقه‌ی دیگر دوباره درخواست بده"})
    elsif too_many then
      res.status_code(429)
      res.json({error="صف درخواست‌ها فعلاً پر است"})
    else
      auto_accept = by_file and request_mode() == "auto"
      state = if auto_accept then "queued" else "pending" end
      db.exec("INSERT INTO requests (listener, name, file, body, at, status) VALUES (#{l}, #{sqlite.escape(name)}, #{f}, #{sqlite.escape(text)}, #{now}, #{sqlite.escape(state)})")
      if auto_accept then play_next(wanted) end
      res.json({ok=true, status=state})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

def requests_json() =
  now = time()
  since = now - 86400.
  rows = db.query("SELECT id, name, file, body, at, status FROM requests WHERE status IN ('pending', 'queued') OR done_at > #{since} ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, id DESC LIMIT 300")
  {
    mode = request_mode(),
    time = now,
    pending = db_int("SELECT COUNT(*) AS n FROM requests WHERE status = 'pending'", "n"),
    items = list.map(fun (r) -> begin
      f = col(r, "file")
      {id=int_of_string(col(r, "id"), default=0), name=col(r, "name"), file=f, label=(if f != "" then label_of(f) else "" end), text=col(r, "body"), at=float_of_string(col(r, "at")), status=col(r, "status")}
    end, rows)
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/requests", fun (req, res) -> admin(req, res, fun () -> res.json(requests_json())))

# Accepting a track puts it in "play next" once and moves every listener who asked for it to queued.
harbor.http.register(port=panel_port, method="POST", "/api/requests/accept", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    rows = db.query("SELECT file FROM requests WHERE id = #{p.id} AND status = 'pending'")
    if list.length(rows) > 0 then
      wanted = col(list.hd(rows), "file")
      f = sqlite.escape(wanted)
      now = time()
      if wanted == "" then db.exec("UPDATE requests SET status = 'done', done_at = #{now} WHERE id = #{p.id}")
      elsif valid(wanted) then
        if not list.mem(wanted, queued_files()) then play_next(wanted) end
        db.exec("UPDATE requests SET status = 'queued', done_at = #{now} WHERE file = #{f} AND status = 'pending'")
      else db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE file = #{f} AND status = 'pending'") end
    end
    res.json(requests_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/requests/reject", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    rows = db.query("SELECT file FROM requests WHERE id = #{p.id} AND status = 'pending'")
    if list.length(rows) > 0 then
      wanted = col(list.hd(rows), "file")
      now = time()
      if wanted == "" then db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE id = #{p.id}")
      else db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE file = #{sqlite.escape(wanted)} AND status = 'pending'") end
    end
    res.json(requests_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# removes everything that is no longer waiting (the answered ones)
harbor.http.register(port=panel_port, method="POST", "/api/requests/clear", fun (req, res) -> admin(req, res, fun () -> begin
  db.exec("DELETE FROM requests WHERE status NOT IN ('pending', 'queued')")
  res.json(requests_json())
end))

harbor.http.register(port=panel_port, method="POST", "/api/requests/mode", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {mode: string}) = req.body(timeout=5.)
    if p.mode == "auto" or p.mode == "manual" then
      db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('request_mode', #{sqlite.escape(p.mode)})")
    end
    res.json(requests_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

def settings_json() =
  {catalog_public=catalog_public(), request_mode=request_mode()}
end

harbor.http.register(port=panel_port, method="GET", "/api/settings", fun (req, res) -> admin(req, res, fun () -> res.json(settings_json())))

# {catalog_public}: whether listeners can search the library when requesting a song
harbor.http.register(port=panel_port, method="POST", "/api/settings", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {catalog_public: bool}) = req.body(timeout=5.)
    value = if p.catalog_public then "1" else "0" end
    db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('catalog_public', #{sqlite.escape(value)})")
    res.json(settings_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# ---------- uploads ----------
# An upload is kept in .incoming - quarantine: a dot-folder, so not in the library, the catalog or the
# playlist - until the admin approves it. (nginx can't hand the file over itself: it writes its temp files
# 0600 as the nginx user, which the radio's user can't read.)
def hdr(req, name) =
  v = ref("")
  list.iter(fun (h) -> if string.case(lower=true, fst(h)) == name then v := snd(h) end, req.headers)
  v()
end

def upload_used() =
  db_int("SELECT COALESCE(SUM(size), 0) AS n FROM uploads WHERE status = 'pending'", "n")
end

def upload_path(stored) =
  "#{upload_dir}/#{stored}"
end

# The raw file is the request body; who sent it and what it is called travel in X-Listener, X-Name
# and X-Filename (URL-encoded). nginx caps the body at upload_max_bytes before it gets here.
harbor.http.register(port=panel_port, method="POST", "/api/upload", fun (req, res) -> begin
  try
    body = req.body(timeout=120.)
    size = string.length(encoding="ascii", body)
    listener = hdr(req, "x-listener")
    name = string.trim(url.decode(hdr(req, "x-name")))
    orig = url.decode(hdr(req, "x-filename"))
    ext = string.case(lower=true, r/^.*\./.replace(fun (_) -> "", orig))
    now = time()
    l = sqlite.escape(listener)
    bad = not valid_listener(listener) or not is_audio(orig) or string.length(name) > name_max or size <= 0
    too_big = size > upload_max_bytes
    too_soon = db_int("SELECT COUNT(*) AS n FROM uploads WHERE listener = #{l} AND at > #{now - upload_gap}", "n") > 0
    waiting = db_int("SELECT COUNT(*) AS n FROM uploads WHERE status = 'pending'", "n")
    full = waiting >= upload_pending_max or upload_used() + size > upload_quota_bytes
    if bad then
      res.status_code(400)
      res.json({error="فایل یا اطلاعاتش درست نیست"})
    elsif too_big then
      res.status_code(413)
      res.json({error="حجم فایل بیشتر از حد مجاز است"})
    elsif too_soon then
      res.status_code(429)
      res.json({error="چند دقیقه‌ی دیگر می‌توانی آهنگ دیگری بفرستی"})
    elsif full then
      res.status_code(429)
      res.json({error="صف آهنگ‌های ارسالی فعلاً پر است"})
    else
      if not file.exists(upload_dir) then file.mkdir(parents=true, upload_dir) end
      stored = "#{int_of_float(now * 1000.)}.#{ext}"
      file.write(data=body, upload_path(stored))
      secs = request.duration(upload_path(stored)) ?? 0.
      r = request.create(upload_path(stored))
      decodes = request.resolve(r)
      if not decodes or secs <= 0. or secs > upload_max_seconds then
        file.remove(upload_path(stored))
        res.status_code(400)
        res.json({error="فایل صوتی معتبر نیست یا بیشتر از ۱۵ دقیقه است"})
      else
        db.exec("INSERT INTO uploads (listener, name, orig, stored, size, secs, at, status) VALUES (#{l}, #{sqlite.escape(name)}, #{sqlite.escape(orig)}, #{sqlite.escape(stored)}, #{size}, #{secs}, #{now}, 'pending')")
        res.json({ok=true})
      end
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

def uploads_json() =
  rows = db.query("SELECT id, name, orig, size, secs, at FROM uploads WHERE status = 'pending' ORDER BY id")
  {
    time = time(),
    used = upload_used(),
    quota = upload_quota_bytes,
    max_bytes = upload_max_bytes,
    items = list.map(fun (r) -> {
      id = int_of_string(col(r, "id"), default=0),
      name = col(r, "name"),
      orig = col(r, "orig"),
      size = int_of_string(col(r, "size"), default=0),
      secs = float_of_string(col(r, "secs")),
      at = float_of_string(col(r, "at"))
    }, rows)
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/uploads", fun (req, res) -> admin(req, res, fun () -> res.json(uploads_json())))

# the quarantined file itself, for the admin to listen to before deciding
harbor.http.register(port=panel_port, method="GET", "/api/uploads/audio", fun (req, res) -> admin(req, res, fun () -> begin
  wanted = int_of_string(req.query["id"], default=0)
  rows = db.query("SELECT stored FROM uploads WHERE status = 'pending' AND id = #{wanted}")
  stored = if list.length(rows) > 0 then col(list.hd(rows), "stored") else "" end
  if stored != "" and file.exists(upload_path(stored)) then
    res.content_type("application/octet-stream")
    res.data(file.contents(upload_path(stored)))
  else
    res.status_code(404)
    res.data("")
  end
end))

# A file name that is safe on every filesystem and can't start a dot-file (those are hidden from the library).
def safe_name(orig) =
  n = r/[\/\\:*?"<>|'`#%;\x00-\x1f]/g.replace(fun (_) -> "_", string.trim(orig))
  r/^\.+/.replace(fun (_) -> "", n)
end

# {id, next}: moves the file into the library folder (radio/Uploads) and, with next, plays it next
harbor.http.register(port=panel_port, method="POST", "/api/uploads/approve", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int, next: bool}) = req.body(timeout=5.)
    rows = db.query("SELECT stored, orig FROM uploads WHERE status = 'pending' AND id = #{p.id}")
    if list.length(rows) > 0 then
      stored = col(list.hd(rows), "stored")
      orig = safe_name(col(list.hd(rows), "orig"))
      dir = "#{radio_dir}/#{upload_dest}"
      if not file.exists(dir) then file.mkdir(parents=true, dir) end
      # never overwrite: "x.mp3" -> "x (2).mp3"
      stem = r/\.[A-Za-z0-9]+$/.replace(fun (_) -> "", orig)
      ext = r/^.*\./.replace(fun (_) -> "", orig)
      final = ref(orig)
      n = ref(1)
      while file.exists("#{dir}/#{final()}") do
        n := n() + 1
        final := "#{stem} (#{n()}).#{ext}"
      end
      file.move(upload_path(stored), "#{dir}/#{final()}")
      dest = "radio/#{upload_dest}/#{final()}"
      db.exec("UPDATE uploads SET status = 'approved', dest = #{sqlite.escape(dest)} WHERE id = #{p.id}")
      scan_library()
      if p.next then play_next(dest) end
    end
    res.json(uploads_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/uploads/reject", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    rows = db.query("SELECT stored FROM uploads WHERE status = 'pending' AND id = #{p.id}")
    if list.length(rows) > 0 then
      stored = col(list.hd(rows), "stored")
      if file.exists(upload_path(stored)) then file.remove(upload_path(stored)) end
      db.exec("UPDATE uploads SET status = 'rejected' WHERE id = #{p.id}")
    end
    res.json(uploads_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# Housekeeping, hourly: a pending upload nobody answered within a week is deleted, and so is any file in
# .incoming that the table doesn't know (left behind by a crash between writing the file and the row).
thread.run(every=3600., fun () -> begin
  old = db.query("SELECT id, stored FROM uploads WHERE status = 'pending' AND at < #{time() - upload_keep_seconds}")
  list.iter(fun (r) -> begin
    stored = col(r, "stored")
    id = col(r, "id")
    if file.exists(upload_path(stored)) then file.remove(upload_path(stored)) end
    db.exec("UPDATE uploads SET status = 'expired' WHERE id = #{id}")
  end, old)
  if file.exists(upload_dir) then
    known = list.map(fun (r) -> upload_path(col(r, "stored")), db.query("SELECT stored FROM uploads WHERE status = 'pending'"))
    list.iter(fun (f) -> if not list.mem(f, known) then file.remove(f) end, file.ls(absolute=true, upload_dir))
  end
end)

harbor.http.register(port=panel_port, method="GET", "/api/library", fun (req, res) -> admin(req, res, fun () -> begin
  if req.query["refresh"] != "" or list.length(library_cache()) == 0 then scan_library() end
  res.json(library_cache())
end))

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
    play_next(p.file)
  end
end)

api("hidden", fun (body) -> begin
  let json.parse (p : {file: string, hidden: bool}) = body
  if p.hidden then
    if valid(p.file) and not list.mem(p.file, hidden()) then hidden := list.append(hidden(), [p.file]) end
  else
    hidden := list.filter(fun (x) -> x != p.file, hidden())
  end
  save_hidden()
  m = current()
  if rel(m["filename"]) == p.file and not live_airing() then
    meta_in.insert_metadata(new_track=false,
      if is_hidden(p.file) then [("title", hidden_title)] else [("title", m["title"]), ("artist", m["artist"])] end)
  end
end)

api("live/allow", fun (body) -> begin
  let json.parse (p : {allowed: bool}) = body
  live_allowed := p.allowed
end)

harbor.http.register(port=panel_port, method="POST", "/api/live/token", fun (req, res) -> admin(req, res, fun () ->
  res.json({token=live_token(), port=live_port, mount="live"})))

api("queue/clear", fun (_) -> begin
  touch()
  give_back(keep_next=false)
  upcoming := []
  touch()
  auto.set_queue([])
end)

output.icecast(
  %mp3(bitrate=320),
  host="icecast",
  port=8000,
  password=environment.get("ICECAST_SOURCE_PASSWORD"),
  mount="/radio",
  name="LAN Radio",
  description="Music from the local network",
  genre="Mixed",
  mksafe(radio)
)
