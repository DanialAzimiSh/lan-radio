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

# Total capacity shared with Icecast; channel 0 is included.
max_channels_text = environment.get("MAX_CHANNELS")
max_channels_text = if max_channels_text == "" then "6" else max_channels_text end
max_channels = int_of_string(max_channels_text, default=0)
if not r/^[1-9][0-9]*$/.test(max_channels_text) or max_channels < 1 then
  error.raise(error.register("config"), "MAX_CHANNELS must be a positive integer (including the main channel)")
end

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
extra_hidden_refresh = ref(fun (_) -> ())
extra_plays = ref([])
extra_enqueue = ref(fun (_, _) -> false)
extra_queued = ref(fun (_) -> [])
extra_eq_update = ref(fun (_, _, _) -> ())
extra_clip_state = ref(fun (_) -> {name="", active=false, remaining=0.})
extra_clip_play = ref(fun (_, _) -> {code=404, error="کانال پیدا نشد"})

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

def requested_channel(req) =
  int_of_string(req.query["channel"], default=0)
end

def channel_valid(id) =
  id == 0 or (id > 0 and db_int("SELECT COUNT(*) AS n FROM channels WHERE id = #{id}", "n") > 0)
end

def channel_track_key(id, file) =
  if id == 0 then file else "#{id}:#{file}" end
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
  "CREATE TABLE uploads (id INTEGER PRIMARY KEY AUTOINCREMENT, listener TEXT NOT NULL, name TEXT NOT NULL, orig TEXT NOT NULL, stored TEXT NOT NULL, size INTEGER NOT NULL, secs REAL NOT NULL, at REAL NOT NULL, status TEXT NOT NULL, dest TEXT NOT NULL DEFAULT '')",
  "CREATE TABLE plays (id INTEGER PRIMARY KEY AUTOINCREMENT, file TEXT NOT NULL, at REAL NOT NULL)",
  "CREATE INDEX plays_file ON plays (file)",
  "CREATE INDEX plays_at ON plays (at)",
  "CREATE TABLE loudness (file TEXT PRIMARY KEY, gain REAL NOT NULL, at REAL NOT NULL)",
  "CREATE TABLE notices (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL, quote_name TEXT NOT NULL, quote_text TEXT NOT NULL, image TEXT NOT NULL, style TEXT NOT NULL, at REAL NOT NULL, expires REAL NOT NULL, ended REAL NOT NULL DEFAULT 0)",
  "ALTER TABLE messages ADD COLUMN notice_id INTEGER NOT NULL DEFAULT 0",
  "CREATE TABLE notes (track TEXT PRIMARY KEY, description TEXT NOT NULL DEFAULT '', facts TEXT NOT NULL DEFAULT '')",
  "ALTER TABLE notices ADD COLUMN message_id INTEGER NOT NULL DEFAULT 0",
  "UPDATE notices SET message_id = (SELECT id FROM messages WHERE notice_id = notices.id LIMIT 1) WHERE id IN (SELECT notice_id FROM messages WHERE notice_id > 0)",
  "CREATE TABLE channels (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, tracks TEXT NOT NULL DEFAULT '', mode TEXT NOT NULL DEFAULT 'normal', paused INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL)",
  "ALTER TABLE messages ADD COLUMN channel_id INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE requests ADD COLUMN channel_id INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE uploads ADD COLUMN channel_id INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE notices ADD COLUMN channel_id INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE plays ADD COLUMN channel_id INTEGER NOT NULL DEFAULT 0"
]
schema_version = db_int("PRAGMA user_version", "user_version")
list.iteri(fun (i, sql) -> if i >= schema_version then begin
  log.important("database: migration #{i + 1}")
  db.exec(sql)
  db.exec("PRAGMA user_version = #{i + 1}")
end end, migrations)

def meta_get(key, fallback) =
  rows = db.query("SELECT value FROM meta WHERE key = #{sqlite.escape(key)}")
  if list.length(rows) > 0 then col(list.hd(rows), "value") else fallback end
end

def meta_set(key, value) =
  db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (#{sqlite.escape(key)}, #{sqlite.escape(value)})")
end

def channel_meta_key(channel, key) =
  if channel == 0 then key else "channel_#{channel}_#{key}" end
end

def channel_meta_get(channel, key, fallback) =
  meta_get(channel_meta_key(channel, key), fallback)
end

def channel_meta_set(channel, key, value) =
  meta_set(channel_meta_key(channel, key), value)
end

def note_of(file) =
  rows = db.query("SELECT description, facts FROM notes WHERE track = #{sqlite.escape(file)}")
  if list.length(rows) == 0 then {description="", facts=""}
  else
    r = list.hd(rows)
    {description=col(r, "description"), facts=col(r, "facts")}
  end
end

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
live_tallies = ref([])
zero_tally = {fire=0, clap=0, wow=0, sleep=0}

def live_taps(id) =
  hits = list.filter(fun (x) -> fst(x) == id, live_tallies())
  if list.length(hits) > 0 then snd(list.hd(hits)) else zero_tally end
end

def tap_live(id, kind) =
  t = live_taps(id)
  def up(k, v) =
    if kind == k then v + 1 else v end
  end
  next = {fire=up("fire", t.fire), clap=up("clap", t.clap), wow=up("wow", t.wow), sleep=up("sleep", t.sleep)}
  live_tallies := list.prefix(100, (id, next) :: list.filter(fun (x) -> fst(x) != id, live_tallies()))
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

# ---------- jingles, hour announcements, notices ----------
# Jingles: any audio in radio/Jingles, one every `jingle_every` tracks. Hour announcements: radio/Time/HH.mp3
# (00..23), aired by the first track change after the hour turns. Neither folder is part of the library.
# A notice is something the admin shows every listener on the page (text, an image, or a public reply to a
# message); its image lives in a dot-folder served only through /api/notice/image.
jingle_dir = "#{radio_dir}/Jingles"
time_dir = "#{radio_dir}/Time"
clip_max_bytes = 8 * 1024 * 1024
clip_max_seconds = 120.
notice_dir = "#{radio_dir}/.notices"
notice_image_max = 3 * 1024 * 1024
notice_title_max = 80
notice_body_max = 600
notice_shown_max = 8
notice_ttl_max = 30 * 24 * 3600
# the stats section asks Prometheus (optional) through the radio, so the panel needs no CORS or second login
prometheus_url = environment.get("PROMETHEUS_URL")
settings.prometheus.server.set(true)

def reaction_counts(file) =
  rows = db.query("SELECT kind, COUNT(*) AS n FROM reactions WHERE track = #{sqlite.escape(file)} GROUP BY kind")
  def n(k) =
    v = ref(0)
    list.iter(fun (r) -> if col(r, "kind") == k then v := int_of_string(col(r, "n"), default=0) end, rows)
    v()
  end
  {fire=n("fire"), clap=n("clap"), wow=n("wow"), sleep=n("sleep")}
end

def messages_json(~channel=0) =
  rows = db.query("SELECT m.id, m.name, m.body, m.title, m.at, m.is_read, (SELECT COUNT(*) FROM notices n WHERE n.message_id = m.id) AS reply_count FROM messages m WHERE m.channel_id = #{channel} ORDER BY m.id DESC LIMIT 200")
  {
    unread = db_int("SELECT COUNT(*) AS n FROM messages WHERE channel_id = #{channel} AND is_read = 0", "n"),
    time = time(),
    items = list.map(fun (r) -> {
      id = int_of_string(col(r, "id"), default=0),
      name = col(r, "name"),
      text = col(r, "body"),
      title = col(r, "title"),
      at = float_of_string(col(r, "at")),
      read = col(r, "is_read") == "1",
      replied = col(r, "reply_count") != "0",
      reply_count = int_of_string(col(r, "reply_count"), default=0)
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

def tag(r, key) =
  m = request.metadata(r)
  m[key]
end

# ---------- loudness, jingles, hour announcements ----------
# Loudness: a background worker measures every file once (ReplayGain, ~5 s of CPU each) into the `loudness`
# table; a pick carries the file's gain (plus the panel's offset) as its replaygain tag and the replaygain
# operator in front of the output applies it. A file nobody measured yet simply plays as it is.
fa_hours = ["۰۰", "۰۱", "۰۲", "۰۳", "۰۴", "۰۵", "۰۶", "۰۷", "۰۸", "۰۹", "۱۰", "۱۱", "۱۲", "۱۳", "۱۴", "۱۵", "۱۶", "۱۷", "۱۸", "۱۹", "۲۰", "۲۱", "۲۲", "۲۳"]
air_end = ref(0.)
last_hour = ref(time.local(time()).hour)
since_jingle = ref(0)

def loudness_on() =
  meta_get("loudness", "1") == "1"
end

def loudness_offset() =
  float_of_int(int_of_string(meta_get("loudness_offset", "2"), default=2))
end

def jingle_every() =
  int_of_string(meta_get("jingle_every", "5"), default=5)
end

def time_announce() =
  meta_get("time_announce", "1") == "1"
end

def loudness_tag(e) =
  if not loudness_on() then ""
  else
    rows = db.query("SELECT gain FROM loudness WHERE file = #{sqlite.escape(e)}")
    gain = if list.length(rows) > 0 then float_of_string(default=0., col(list.hd(rows), "gain")) else 0. end
    if gain == 0. then "" else "replaygain_track_gain=\"#{gain + loudness_offset()} dB\"" end
  end
end

def loudness_tag_channel(id, e) =
  if id == 0 then loudness_tag(e)
  elsif channel_meta_get(id, "loudness", "1") != "1" then ""
  else
    rows = db.query("SELECT gain FROM loudness WHERE file = #{sqlite.escape(e)}")
    gain = if list.length(rows) > 0 then float_of_string(default=0., col(list.hd(rows), "gain")) else 0. end
    offset = int_of_string(channel_meta_get(id, "loudness_offset", "2"), default=2)
    if gain == 0. then "" else "replaygain_track_gain=\"#{gain + float_of_int(offset)} dB\"" end
  end
end

def track_request_channel(id, e, tags) =
  g = loudness_tag_channel(id, e)
  all = if g != "" then "#{tags},#{g}" else tags end
  request.create("annotate:#{all}:#{library}/#{e}")
end

def clip_request_channel(id, path, kind, title) =
  g = loudness_tag_channel(id, rel(path))
  more = if g != "" then ",#{g}" else "" end
  request.create("annotate:radio_from=\"#{kind}\",radio_kind=\"#{kind}\",title=\"#{title}\",artist=\"\"#{more}:#{path}")
end

def track_request(e, tags) =
  g = loudness_tag(e)
  all = if g != "" then "#{tags},#{g}" else tags end
  request.create("annotate:#{all}:#{library}/#{e}")
end

def clip_request(path, kind, title, extra) =
  g = loudness_tag(rel(path))
  more = if g != "" then ",#{g}" else "" end
  request.create("annotate:radio_from=\"#{kind}\",radio_kind=\"#{kind}\",title=\"#{title}\",artist=\"\"#{extra}#{more}:#{path}")
end

def clip_of_hour(h) =
  hh = if h < 10 then "0#{h}" else "#{h}" end
  if not file.exists(time_dir) then ""
  else
    hits = list.filter(fun (n) -> string.contains(prefix="#{hh}.", n) and is_audio(n), file.ls(time_dir))
    if list.length(hits) > 0 then "#{time_dir}/#{list.hd(hits)}" else "" end
  end
end

def jingle_files() =
  if file.exists(jingle_dir) then list.filter(is_audio, file.ls(absolute=true, sorted=true, jingle_dir)) else [] end
end

# The clip that has to air before the next library track, or null. The next track starts when the one on air
# ends (air_end), so an hour that turns before then is announced by this very change of track.
def special() =
  start = if air_end() > time() then air_end() else time() end
  hour = time.local(start).hour
  hit = if time_announce() and hour != last_hour() then clip_of_hour(hour) else "" end
  if hit == "" and hour != last_hour() then last_hour := hour end
  jingles = jingle_files()
  # the counters move here, at pick time: the pick after this one runs before on_track has fired
  if hit != "" then
    last_hour := hour
    null(clip_request(hit, "time", "🕐 ساعت #{list.nth(fa_hours, hour)}", ""))
  elsif jingle_every() > 0 and since_jingle() >= jingle_every() and list.length(jingles) > 0 then
    since_jingle := 0
    null(clip_request(list.nth(jingles, random.int(min=0, max=list.length(jingles))), "jingle", "🎙 رادیو", ""))
  else null() end
end

# Bumped by every panel change, so a pick that was resolving meanwhile starts over instead of
# landing a track chosen under the old state.
version = ref(0)
def touch() =
  version := version() + 1
end

# Each pick is tagged with where it came from, so give_back() can undo it once it is queued.
# The pick is only taken (queue popped, cursor moved) after the file resolved under an unchanged state.
def rec pick_track() =
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
    if version() != v then pick_track()
    else
      if from_next then upcoming := list.tl(upcoming())
      elsif mode() == "randomize" then bag := list.tl(bag())
      elsif mode() == "normal" then cursor := i + 1 end
      if ok then null(r) else null() end
    end
  end
end

# a jingle or the hour announcement goes first when it is due; a clip that won't play is skipped
def pick() =
  clip = special()
  clip_ok = if null.defined(clip) then request.resolve(null.get(clip)) else false end
  if clip_ok then clip
  else
    r = pick_track()
    if null.defined(r) then since_jingle := since_jingle() + 1 end
    r
  end
end

load_state()
load_playlist()

# Prometheus scrapes :9599/metrics. A gauge/counter is made once and returns its setter.
def gauge(name, help) =
  g = prometheus.gauge(namespace="radio", help=help, labels=[], name)
  g(label_values=[])
end
m_listeners = gauge("listeners", "Listeners connected to the stream")
m_live = gauge("live", "1 while a live source is on air")
m_paused = gauge("paused", "1 while the radio is paused")
m_likes = gauge("likes", "Likes stored")
m_reactions = gauge("reactions", "Reactions stored")
m_messages = gauge("messages_unread", "Unread messages to the admin")
m_requests = gauge("requests_pending", "Song requests waiting for the admin")
m_uploads = gauge("uploads_pending", "Uploaded songs waiting for the admin")
m_measured = gauge("loudness_measured", "Library files whose loudness is measured")
plays_count = prometheus.counter(namespace="radio", help="Library tracks played", labels=[], "plays_total")
plays_counter = plays_count(label_values=[])

#   upcoming ("play next") ─┐
#                           ├─ pick() ─> auto [1 prefetched] ─┐
#   tracks + mode + cursor ─┘                                 ├─ live switch ─> pause switch ─> crossfade ─> icecast
#                                    live (:8005/live) ───────┘
# Both switches sit before crossfade so crossfade is never starved (it wedges if left mid-transition);
# pausing or going live fades over and leaves auto unread, so the music resumes the same track.
auto = request.dynamic(id="auto", retry_delay=2., pick)
auto.on_track(fun (m) -> begin
  kind = m["radio_kind"]
  played = rel(m["filename"])
  current := m
  if kind == "" then
    on_air := int_of_string(m["radio_index"], default=-1)
    save_state()
    db.exec("INSERT INTO plays (file, at, channel_id) VALUES (#{sqlite.escape(played)}, #{time()}, 0)")
    plays_counter(1.)
  end
  air_end := time() + (request.duration(m["filename"]) ?? 0.)
  play_seq := play_seq() + 1
  history := list.prefix(12, {id=play_seq(), file=rel(m["filename"]), title=m["title"], artist=m["artist"], kind=kind, at=time()} :: history())
  aired = rel(m["filename"])
  db.exec("UPDATE requests SET status = 'played', done_at = #{time()} WHERE channel_id = 0 AND status = 'queued' AND file = #{sqlite.escape(aired)}")
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
extra_live_tokens = ref([])

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

def channel_live_token(id) =
  t = "#{random.int(min=100000000, max=999999999)}#{random.int(min=100000000, max=999999999)}"
  extra_live_tokens := (id, t) :: list.prefix(20, extra_live_tokens())
  thread.run(delay=120., fun () -> extra_live_tokens := list.filter(fun (x) -> x != (id, t), extra_live_tokens()))
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

# replaygain applies the gain a pick carries (none when normalising is off or the file is not measured yet);
# limit catches the peaks a boosted quiet file would otherwise clip
levelled = limit(id="limit", threshold=-1., replaygain(id="levelling", auto))
on_air_source = switch(id="source", track_sensitive=false, [({live_allowed()}, live_feed), ({true}, levelled)])
music = switch(id="music", track_sensitive=false, [({not paused()}, on_air_source), ({true}, blank(id="paused"))])
radio = crossfade(duration=crossfade_seconds, fade_in=crossfade_seconds, fade_out=crossfade_seconds, music)

# Manual jingles sit on top of the current stream, without advancing or replacing its track.
# The song ducks over 350 ms and recovers over 700 ms after the clip's measured duration.
manual_jingle = request.player(simultaneous=false)
manual_jingle_name = ref("")
manual_jingle_started = ref(0.)
manual_jingle_until = ref(0.)
manual_jingle_starting = ref(false)
def manual_jingle_active() =
  manual_jingle_started() > 0. and time() < manual_jingle_until()
end
duck_level = ref(1.)
duck_tick = ref(time())
def duck_gain() =
  now = time()
  delta = max(0., min(0.1, now - duck_tick()))
  duck_tick := now
  target = if manual_jingle_active() then 0.28 else 1. end
  step = if target < duck_level() then delta * 0.72 / 0.35 else delta * 0.72 / 0.7 end
  duck_level := if target < duck_level() then max(target, duck_level() - step) else min(target, duck_level() + step) end
  duck_level()
end
radio = add(id="manual_jingle_mix", normalize=false, [amplify(id="jingle_duck", override=null(), fun () -> duck_gain(), radio), manual_jingle])

# Seven peaking bands on the common output, including live audio. FFmpeg's filter commands change
# gain while broadcasting; settings are persisted in SQLite and restored when Liquidsoap starts.
eq_enabled = ref(meta_get("eq_enabled", "0") == "1")
eq_gains = ref(list.map(fun (i) -> float_of_string(meta_get("eq_#{i}", "0"), default=0.), [0, 1, 2, 3, 4, 5, 6]))
eq_setters = ref([])

def eq_gain(i) = if eq_enabled() then list.nth(eq_gains(), i) else 0. end end

def equalize(s) =
  def mkfilter(graph) =
    def band(input, frequency, i) =
      f = ffmpeg.filter.equalizer.create(frequency=frequency, width_type=3, width=1., gain=eq_gain(i), graph)
      f.set_input(input)
      (f.output, fun (gain) -> ignore(f.process_command("gain", "#{gain}")))
    end
    let {audio = original} = source.tracks(s)
    a = ffmpeg.filter.audio.input(graph, original)
    let (a, set0) = band(a, 60., 0)
    let (a, set1) = band(a, 150., 1)
    let (a, set2) = band(a, 400., 2)
    let (a, set3) = band(a, 1000., 3)
    let (a, set4) = band(a, 2500., 4)
    let (a, set5) = band(a, 6000., 5)
    let (a, set6) = band(a, 12000., 6)
    eq_setters := [set0, set1, set2, set3, set4, set5, set6]
    a = ffmpeg.filter.audio.output(graph, a)
    source({audio=a, metadata=track.metadata(a), track_marks=track.track_marks(a)})
  end
  ffmpeg.filter.create(mkfilter)
end

radio = ffmpeg.raw.decode.audio(equalize(ffmpeg.raw.encode.audio(%ffmpeg(%audio.raw), radio)))
radio = limit(id="eq_peak_limit", threshold=-1., radio)

def apply_eq() =
  list.iteri(fun (i, set_gain) -> set_gain(eq_gain(i)), eq_setters())
end

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
  clips = ["radio/Jingles/", "radio/Time/"]
  library_cache := list.filter(fun (e) -> is_audio(e) and not string.contains(substring="/.", e) and list.length(list.filter(fun (c) -> string.contains(prefix=c, e), clips)) == 0, list.map(rel, files))
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
    messages_unread = db_int("SELECT COUNT(*) AS n FROM messages WHERE channel_id = 0 AND is_read = 0", "n"),
    requests_pending = db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = 0 AND status = 'pending'", "n"),
    uploads_pending = db_int("SELECT COUNT(*) AS n FROM uploads WHERE channel_id = 0 AND status = 'pending'", "n")
  }
end

extra_status = ref(fun (_) -> status())
extra_control = ref(fun (_, _, _) -> error.raise(error.register("channel"), "کنترل کانال در دسترس نیست"))

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
      ch = requested_channel(req)
      body = req.body(timeout=5.)
      if ch == 0 then handler(body)
      else control = extra_control(); control(ch, path, body) end
      get_status = extra_status()
      res.json(if ch == 0 then status() else get_status(ch) end)
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
  elsif r/\.woff2$/.test(f) then "font/woff2"
  else null() end
end
harbor.http.static(port=panel_port, path="/panel", content_type=panel_type, headers=[("Cache-Control", "no-cache")], panel_dir)
harbor.http.register(port=panel_port, method="GET", "/api/status", fun (req, res) -> admin(req, res, fun () -> begin
  ch = requested_channel(req)
  get_status = extra_status()
  res.json(if ch == 0 then status() else get_status(ch) end)
end))

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
def catalog_public(~channel=0) =
  key = if channel == 0 then "catalog_public" else "channel_#{channel}_catalog_public" end
  rows = db.query("SELECT value FROM meta WHERE key = #{sqlite.escape(key)}")
  list.length(rows) > 0 and col(list.hd(rows), "value") == "1"
end

# "Persian/Artist - Song.mp3" -> "Artist - Song"
def label_of(file) =
  parts = string.split(separator="/", file)
  r/\.[A-Za-z0-9]+$/.replace(fun (_) -> "", list.hd(default=file, list.rev(parts)))
end

# the listener's own recent requests, so the page can show where each one stands
def mine_requests(listener, ~channel=0) =
  if listener == "" then []
  else
    since = time() - 600.
    rows = db.query("SELECT id, file, body, status FROM requests WHERE channel_id = #{channel} AND listener = #{sqlite.escape(listener)} AND (status IN ('pending', 'queued') OR done_at > #{since}) ORDER BY id DESC LIMIT 5")
    list.map(fun (r) -> begin
      f = col(r, "file")
      {id=int_of_string(col(r, "id"), default=0), label=(if f != "" then label_of(f) else col(r, "body") end), status=col(r, "status")}
    end, rows)
  end
end

# ---------- notices ----------
# What the admin shows every listener. Active = not ended and not past its expiry; the page shows the newest few.
def notice_row(r) =
  now = time()
  ended = float_of_string(col(r, "ended"))
  expires = float_of_string(col(r, "expires"))
  {
    id = int_of_string(col(r, "id"), default=0),
    title = col(r, "title"),
    body = col(r, "body"),
    quote_name = col(r, "quote_name"),
    quote_text = col(r, "quote_text"),
    image = col(r, "image") != "",
    style = col(r, "style"),
    at = float_of_string(col(r, "at")),
    expires = expires,
    active = ended == 0. and (expires == 0. or expires > now)
  }
end

def notices_public(~channel=0) =
  rows = db.query("SELECT * FROM notices WHERE channel_id = #{channel} AND ended = 0 AND (expires = 0 OR expires > #{time()}) ORDER BY id DESC LIMIT #{notice_shown_max}")
  list.map(notice_row, rows)
end

def public_track(file, title, artist) =
  if is_hidden(file) then {file="", title=hidden_title, artist=""}
  else {file=file, title=title, artist=artist} end
end

# ---------- the lists under the player ----------
# The admin decides whether listeners see "next" and "recently played", and how many rows each shows (one
# number for both). "Next" is what is certain (the prefetched track, then "play next") followed by what the
# order predicts: the rest of the playlist in "normal", the shuffle bag in "randomize"; "random" can't tell.
def show_next(~channel=0) =
  channel_meta_get(channel, "show_next", "1") == "1"
end

def show_recent(~channel=0) =
  channel_meta_get(channel, "show_recent", "1") == "1"
end

# title and artist of a file that has not been through the radio yet, remembered after the first read
tag_cache = ref([])
def file_tags(f) =
  hits = list.filter(fun (kv) -> fst(kv) == f, tag_cache())
  if list.length(hits) > 0 then snd(list.hd(hits))
  else
    md = file.metadata("#{library}/#{f}")
    t = (md["title"], md["artist"])
    tag_cache := (f, t) :: list.prefix(1000, tag_cache())
    t
  end
end

def upcoming_list(count) =
  n = list.length(tracks())
  sure = list.filter(fun (r) -> tag(r, "radio_kind") == "", auto.queue())
  files = list.map(fun (r) -> rel(request.filename(r)), sure)
  guessed =
    if mode() == "normal" and n > 0 then list.init(count, fun (i) -> list.nth(tracks(), (cursor() + i) mod n))
    elsif mode() == "randomize" then list.map(fun (i) -> list.nth(tracks(), i), list.filter(fun (i) -> i >= 0 and i < n, list.prefix(count, bag())))
    else [] end
  wanted = list.append(files, list.append(upcoming(), guessed))
  distinct = list.fold(fun (acc, f) -> if list.mem(f, acc) then acc else list.append(acc, [f]) end, [], wanted)
  list.map(fun (f) -> begin
    t = file_tags(f)
    public_track(f, fst(t), snd(t))
  end, list.prefix(count, distinct))
end

# `listener` is the anonymous id the listener page keeps in the browser; it only marks the listener's own likes.
def public_now(listener) =
  m = current()
  count = 5
  n = public_track(rel(m["filename"]), m["title"], m["artist"])
  # history[0] is the track on air (unless nothing has played yet); the list under it is the admin's choice
  all = history()
  later = if list.length(all) > 0 then list.tl(all) else [] end
  shown = if show_recent() then list.append(list.prefix(1, all), list.prefix(count, list.filter(fun (h) -> h.kind == "", later))) else list.prefix(1, all) end
  plays = list.map(fun (h) -> begin
    p = public_track(h.file, h.title, h.artist)
    {id=h.id, file=p.file, title=p.title, artist=p.artist, kind=h.kind, at=h.at, likes=like_count(h.file), liked=liked_by(listener, h.file)}
  end, shown)
  on = list.hd(default={id=-1, file="", title="", artist="", kind="", at=0., likes=0, liked=false}, plays)
  coming = if show_next() then upcoming_list(count) else [] end
  note = if n.file != "" and on.kind == "" then note_of(n.file) else {description="", facts=""} end
  {
    paused = paused(),
    time = time(),
    now = {id=on.id, kind=on.kind, file=n.file, title=n.title, artist=n.artist, elapsed=auto.elapsed(), duration=auto.duration(), likes=on.likes, liked=on.liked, reactions=live_taps(on.id), description=note.description, facts=note.facts},
    mine = mine_requests(listener),
    notices = notices_public(),
    catalog_open = catalog_public(),
    lists = {next=show_next(), recent=show_recent(), count=count},
    next = list.hd(default={file="", title="", artist=""}, coming),
    upcoming = coming,
    history = plays,
    live = {airing=live_airing(), title=live_title(), since=live_seconds()}
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/now", fun (req, res) -> begin
  l = req.query["listener"]
  try
    res.json(public_now(if valid_listener(l) then l else "" end))
  catch err do
    log.important("api/now: #{err.message}")
    res.status_code(500)
    res.data("{}")
  end
end)

# {play, listener, liked}: play is an id from /api/now's history, so only the last 12 plays can be liked
harbor.http.register(port=panel_port, method="POST", "/api/like", fun (req, res) -> begin
  try
    let json.parse (p : {play: int, listener: string, liked: bool}) = req.body(timeout=5.)
    ch = requested_channel(req)
    files = if ch == 0 then list.map(fun (h) -> h.file, list.filter(fun (h) -> h.id == p.play and h.kind == "", history()))
            else list.map(fun (h) -> h.file, list.filter(fun (h) -> h.id == p.play and h.channel == ch and h.kind == "", extra_plays())) end
    if not channel_valid(ch) or not valid_listener(p.listener) or list.length(files) == 0 then
      res.status_code(400)
      res.json({error="unknown play or listener"})
    else
      key = channel_track_key(ch, list.hd(files))
      f = sqlite.escape(key)
      l = sqlite.escape(p.listener)
      if p.liked then db.exec("INSERT OR IGNORE INTO likes (track, listener, at) VALUES (#{f}, #{l}, #{time()})")
      else db.exec("DELETE FROM likes WHERE track = #{f} AND listener = #{l}") end
      res.json({play=p.play, likes=like_count(key), liked=p.liked})
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
    ch = requested_channel(req)
    files = if ch == 0 then list.map(fun (h) -> h.file, list.filter(fun (h) -> h.id == p.play and h.kind == "", history()))
            else list.map(fun (h) -> h.file, list.filter(fun (h) -> h.id == p.play and h.channel == ch and h.kind == "", extra_plays())) end
    if not channel_valid(ch) or not valid_listener(p.listener) or list.length(files) == 0 or not list.mem(p.kind, reaction_kinds) then
      res.status_code(400)
      res.json({error="unknown play, listener or reaction"})
    else
      f = sqlite.escape(channel_track_key(ch, list.hd(files)))
      l = sqlite.escape(p.listener)
      k = sqlite.escape(p.kind)
      mine = db_int("SELECT COUNT(*) AS n FROM reactions WHERE track = #{f} AND listener = #{l} AND kind = #{k}", "n")
      if mine < reaction_cap then db.exec("INSERT INTO reactions (track, listener, kind, at) VALUES (#{f}, #{l}, #{k}, #{time()})") end
      # a tap that arrives after the track changed is stored but no longer animates for anyone
      cur_id = if ch == 0 then list.hd(default={id=-1, file="", title="", artist="", kind="", at=0.}, history()).id
               else list.hd(default=-1, list.map(fun (h) -> h.id, list.filter(fun (h) -> h.channel == ch, extra_plays()))) end
      if cur_id == p.play then tap_live(p.play, p.kind) end
      res.json({play=cur_id, reactions=live_taps(cur_id)})
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
    ch = requested_channel(req)
    text = string.trim(p.text)
    name = string.trim(p.name)
    now = time()
    l = sqlite.escape(p.listener)
    too_soon = db_int("SELECT COUNT(*) AS n FROM messages WHERE listener = #{l} AND at > #{now - 30.}", "n") > 0
    too_many = db_int("SELECT COUNT(*) AS n FROM messages WHERE at > #{now - 60.}", "n") >= 20
    if not channel_valid(ch) or not valid_listener(p.listener) or text == "" or string.length(text) > message_max or string.length(name) > name_max then
      res.status_code(400)
      res.json({error="پیام خالی است یا بلندتر از حد مجاز"})
    elsif too_soon or too_many then
      res.status_code(429)
      res.json({error="چند لحظه صبر کن و دوباره بفرست"})
    else
      plays = if ch == 0 then list.map(fun (x) -> {file=x.file, title=x.title, artist=x.artist}, list.filter(fun (x) -> x.id == p.play, history()))
              else list.map(fun (x) -> {file=x.file, title=x.title, artist=x.artist}, list.filter(fun (x) -> x.id == p.play and x.channel == ch, extra_plays())) end
      h = list.hd(default={file="", title="", artist=""}, plays)
      live_now = ch == 0 and live_airing()
      label =
        if live_now then "🎙 پخش زنده"
        elsif h.title != "" and h.artist != "" then "#{h.artist} - #{h.title}"
        elsif h.title != "" then h.title
        else h.file end
      file = if live_now then "" else h.file end
      db.exec("INSERT INTO messages (listener, name, body, track, title, at, channel_id) VALUES (#{l}, #{sqlite.escape(name)}, #{sqlite.escape(text)}, #{sqlite.escape(file)}, #{sqlite.escape(label)}, #{now}, #{ch})")
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
harbor.http.register(port=panel_port, method="GET", "/api/messages", fun (req, res) -> admin(req, res, fun () -> res.json(messages_json(channel=requested_channel(req)))))

harbor.http.register(port=panel_port, method="POST", "/api/messages/read", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    db.exec(if p.id > 0 then "UPDATE messages SET is_read = 1 WHERE id = #{p.id} AND channel_id = #{ch}" else "UPDATE messages SET is_read = 1 WHERE channel_id = #{ch}" end)
    res.json(messages_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/messages/delete", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    db.exec(if p.id > 0 then "DELETE FROM messages WHERE id = #{p.id} AND channel_id = #{ch}" else "DELETE FROM messages WHERE channel_id = #{ch} AND is_read = 1" end)
    res.json(messages_json(channel=ch))
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

def request_mode(~channel=0) =
  key = if channel == 0 then "request_mode" else "channel_#{channel}_request_mode" end
  rows = db.query("SELECT value FROM meta WHERE key = #{sqlite.escape(key)}")
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

def catalog(~channel=0) =
  if not catalog_public(channel=channel) then [] else catalog_all() end
end

harbor.http.register(port=panel_port, method="GET", "/api/catalog", fun (req, res) -> begin
  res.header("Cache-Control", "public, max-age=60")
  ch = requested_channel(req)
  res.json(if channel_valid(ch) then catalog(channel=ch) else [] end)
end)

# {listener, name, file, text}: either file (from /api/catalog) or text. 10 minutes between a listener's requests.
harbor.http.register(port=panel_port, method="POST", "/api/request", fun (req, res) -> begin
  try
    let json.parse (p : {listener: string, name: string, file: string, text: string}) = req.body(timeout=5.)
    ch = requested_channel(req)
    now = time()
    l = sqlite.escape(p.listener)
    name = string.trim(p.name)
    text = string.trim(p.text)
    wanted = p.file
    by_file = wanted != ""
    bad_text = string.length(text) > request_text_max or (not by_file and text == "") or (by_file and text != "")
    unknown = by_file and (not valid(wanted) or is_hidden(wanted))
    closed = by_file and not catalog_public(channel=ch)
    too_soon = db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{ch} AND listener = #{l} AND at > #{now - request_gap}", "n") > 0
    too_many = db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{ch} AND status = 'pending'", "n") >= request_pending_max
    f = sqlite.escape(wanted)
    again = by_file and db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{ch} AND listener = #{l} AND file = #{f} AND status IN ('pending', 'queued')", "n") > 0
    on_air_now = by_file and (if ch == 0 then list.length(list.filter(fun (h) -> h.file == wanted, history())) > 0 else list.length(list.filter(fun (h) -> h.channel == ch and h.file == wanted, extra_plays())) > 0 end)
    queued = extra_queued()
    in_queue = by_file and list.mem(wanted, if ch == 0 then queued_files() else queued(ch) end)
    if not channel_valid(ch) or not valid_listener(p.listener) or bad_text or string.length(name) > name_max then
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
      auto_accept = by_file and request_mode(channel=ch) == "auto"
      state = if auto_accept then "queued" else "pending" end
      db.exec("INSERT INTO requests (listener, name, file, body, at, status, channel_id) VALUES (#{l}, #{sqlite.escape(name)}, #{f}, #{sqlite.escape(text)}, #{now}, #{sqlite.escape(state)}, #{ch})")
      if auto_accept then if ch == 0 then play_next(wanted) else enqueue = extra_enqueue(); ignore(enqueue(ch, wanted)) end end
      res.json({ok=true, status=state})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

def requests_json(~channel=0) =
  now = time()
  since = now - 86400.
  rows = db.query("SELECT id, name, file, body, at, status FROM requests WHERE channel_id = #{channel} AND (status IN ('pending', 'queued') OR done_at > #{since}) ORDER BY CASE status WHEN 'pending' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, id DESC LIMIT 300")
  {
    mode = request_mode(channel=channel),
    time = now,
    pending = db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{channel} AND status = 'pending'", "n"),
    items = list.map(fun (r) -> begin
      f = col(r, "file")
      {id=int_of_string(col(r, "id"), default=0), name=col(r, "name"), file=f, label=(if f != "" then label_of(f) else "" end), text=col(r, "body"), at=float_of_string(col(r, "at")), status=col(r, "status")}
    end, rows)
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/requests", fun (req, res) -> admin(req, res, fun () -> res.json(requests_json(channel=requested_channel(req)))))

# Accepting a track puts it in "play next" once and moves every listener who asked for it to queued.
harbor.http.register(port=panel_port, method="POST", "/api/requests/accept", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    rows = db.query("SELECT file FROM requests WHERE id = #{p.id} AND channel_id = #{ch} AND status = 'pending'")
    if list.length(rows) > 0 then
      wanted = col(list.hd(rows), "file")
      f = sqlite.escape(wanted)
      now = time()
      if wanted == "" then db.exec("UPDATE requests SET status = 'done', done_at = #{now} WHERE id = #{p.id} AND channel_id = #{ch}")
      elsif valid(wanted) then
        queued = extra_queued()
        if not list.mem(wanted, if ch == 0 then queued_files() else queued(ch) end) then
          if ch == 0 then play_next(wanted) else enqueue = extra_enqueue(); ignore(enqueue(ch, wanted)) end
        end
        db.exec("UPDATE requests SET status = 'queued', done_at = #{now} WHERE channel_id = #{ch} AND file = #{f} AND status = 'pending'")
      else db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE channel_id = #{ch} AND file = #{f} AND status = 'pending'") end
    end
    res.json(requests_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/requests/reject", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    rows = db.query("SELECT file FROM requests WHERE id = #{p.id} AND channel_id = #{ch} AND status = 'pending'")
    if list.length(rows) > 0 then
      wanted = col(list.hd(rows), "file")
      now = time()
      if wanted == "" then db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE id = #{p.id} AND channel_id = #{ch}")
      else db.exec("UPDATE requests SET status = 'rejected', done_at = #{now} WHERE channel_id = #{ch} AND file = #{sqlite.escape(wanted)} AND status = 'pending'") end
    end
    res.json(requests_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# removes everything that is no longer waiting (the answered ones)
harbor.http.register(port=panel_port, method="POST", "/api/requests/clear", fun (req, res) -> admin(req, res, fun () -> begin
  ch = requested_channel(req)
  db.exec("DELETE FROM requests WHERE channel_id = #{ch} AND status NOT IN ('pending', 'queued')")
  res.json(requests_json(channel=ch))
end))

harbor.http.register(port=panel_port, method="POST", "/api/requests/mode", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {mode: string}) = req.body(timeout=5.)
    ch = requested_channel(req)
    if p.mode == "auto" or p.mode == "manual" then
      key = if ch == 0 then "request_mode" else "channel_#{ch}_request_mode" end
      db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (#{sqlite.escape(key)}, #{sqlite.escape(p.mode)})")
    end
    res.json(requests_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

def settings_json(~channel=0) =
  {
    catalog_public = catalog_public(channel=channel),
    request_mode = request_mode(channel=channel),
    loudness = if channel == 0 then loudness_on() else channel_meta_get(channel, "loudness", "1") == "1" end,
    loudness_offset = if channel == 0 then int_of_float(loudness_offset()) else int_of_string(channel_meta_get(channel, "loudness_offset", "2"), default=2) end,
    loudness_done = db_int("SELECT COUNT(*) AS n FROM loudness", "n"),
    loudness_total = list.length(library_cache()),
    jingle_every = if channel == 0 then jingle_every() else int_of_string(channel_meta_get(channel, "jingle_every", "0"), default=0) end,
    time_announce = if channel == 0 then time_announce() else channel_meta_get(channel, "time_announce", "0") == "1" end,
    show_next = show_next(channel=channel),
    show_recent = show_recent(channel=channel),
    equalizer = {enabled=if channel == 0 then eq_enabled() else channel_meta_get(channel, "eq_enabled", "0") == "1" end,
                 gains=if channel == 0 then eq_gains() else list.map(fun (i) -> float_of_string(channel_meta_get(channel, "eq_#{i}", "0"), default=0.), [0, 1, 2, 3, 4, 5, 6]) end},
    prometheus = channel == 0 and prometheus_url != ""
  }
end

# The two lists can be hidden separately. The listener page shows one row until expanded, up to five.
harbor.http.register(port=panel_port, method="POST", "/api/settings/lists", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {show_next: bool, show_recent: bool}) = req.body(timeout=5.)
    ch = requested_channel(req)
    channel_meta_set(ch, "show_next", if p.show_next then "1" else "0" end)
    channel_meta_set(ch, "show_recent", if p.show_recent then "1" else "0" end)
    res.json(settings_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# {enabled, gains}: seven dB values, from 60 Hz to 12 kHz. Changes take effect on air.
harbor.http.register(port=panel_port, method="POST", "/api/settings/equalizer", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {enabled: bool, gains: [float]}) = req.body(timeout=5.)
    ch = requested_channel(req)
    if list.length(p.gains) != 7 or list.length(list.filter(fun (g) -> not (g >= -9. and g <= 9.), p.gains)) > 0 then
      res.status_code(400)
      res.json({error="باندهای اکولایزر باید بین −۹ و ۹ دسی‌بل باشند"})
    else
      if ch == 0 then
        eq_enabled := p.enabled
        eq_gains := p.gains
        apply_eq()
      else
        update = extra_eq_update()
        update(ch, p.enabled, p.gains)
      end
      channel_meta_set(ch, "eq_enabled", if p.enabled then "1" else "0" end)
      list.iteri(fun (i, g) -> channel_meta_set(ch, "eq_#{i}", "#{g}"), p.gains)
      res.json(settings_json(channel=ch))
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# {loudness, loudness_offset (dB), jingle_every (0 = off), time_announce}
harbor.http.register(port=panel_port, method="POST", "/api/settings/audio", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {loudness: bool, loudness_offset: int, jingle_every: int, time_announce: bool}) = req.body(timeout=5.)
    ch = requested_channel(req)
    if not channel_valid(ch) or p.loudness_offset < -6 or p.loudness_offset > 8 or p.jingle_every < 0 or p.jingle_every > 50 then
      res.status_code(400)
      res.json({error="مقدار تنظیم درست نیست"})
    else
      channel_meta_set(ch, "loudness", if p.loudness then "1" else "0" end)
      channel_meta_set(ch, "loudness_offset", "#{p.loudness_offset}")
      channel_meta_set(ch, "jingle_every", "#{p.jingle_every}")
      channel_meta_set(ch, "time_announce", if p.time_announce then "1" else "0" end)
      res.json(settings_json(channel=ch))
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="GET", "/api/settings", fun (req, res) -> admin(req, res, fun () -> res.json(settings_json(channel=requested_channel(req)))))

# {catalog_public}: whether listeners can search the library when requesting a song
harbor.http.register(port=panel_port, method="POST", "/api/settings", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {catalog_public: bool}) = req.body(timeout=5.)
    ch = requested_channel(req)
    value = if p.catalog_public then "1" else "0" end
    channel_meta_set(ch, "catalog_public", value)
    res.json(settings_json(channel=ch))
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
    ch = requested_channel(req)
    body = req.body(timeout=120.)
    size = string.length(encoding="ascii", body)
    listener = hdr(req, "x-listener")
    name = string.trim(url.decode(hdr(req, "x-name")))
    orig = url.decode(hdr(req, "x-filename"))
    ext = string.case(lower=true, r/^.*\./.replace(fun (_) -> "", orig))
    now = time()
    l = sqlite.escape(listener)
    bad = not channel_valid(ch) or not valid_listener(listener) or not is_audio(orig) or string.length(name) > name_max or size <= 0
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
        db.exec("INSERT INTO uploads (listener, name, orig, stored, size, secs, at, status, channel_id) VALUES (#{l}, #{sqlite.escape(name)}, #{sqlite.escape(orig)}, #{sqlite.escape(stored)}, #{size}, #{secs}, #{now}, 'pending', #{ch})")
        res.json({ok=true})
      end
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end)

def uploads_json(~channel=0) =
  rows = db.query("SELECT id, name, orig, size, secs, at FROM uploads WHERE channel_id = #{channel} AND status = 'pending' ORDER BY id")
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

harbor.http.register(port=panel_port, method="GET", "/api/uploads", fun (req, res) -> admin(req, res, fun () -> res.json(uploads_json(channel=requested_channel(req)))))

# the quarantined file itself, for the admin to listen to before deciding
harbor.http.register(port=panel_port, method="GET", "/api/uploads/audio", fun (req, res) -> admin(req, res, fun () -> begin
  wanted = int_of_string(req.query["id"], default=0)
  rows = db.query("SELECT stored FROM uploads WHERE channel_id = #{requested_channel(req)} AND status = 'pending' AND id = #{wanted}")
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
    ch = requested_channel(req)
    rows = db.query("SELECT stored, orig FROM uploads WHERE channel_id = #{ch} AND status = 'pending' AND id = #{p.id}")
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
      db.exec("UPDATE uploads SET status = 'approved', dest = #{sqlite.escape(dest)} WHERE id = #{p.id} AND channel_id = #{ch}")
      scan_library()
      if p.next then if ch == 0 then play_next(dest) else enqueue = extra_enqueue(); ignore(enqueue(ch, dest)) end end
    end
    res.json(uploads_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/uploads/reject", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    rows = db.query("SELECT stored FROM uploads WHERE channel_id = #{ch} AND status = 'pending' AND id = #{p.id}")
    if list.length(rows) > 0 then
      stored = col(list.hd(rows), "stored")
      if file.exists(upload_path(stored)) then file.remove(upload_path(stored)) end
      db.exec("UPDATE uploads SET status = 'rejected' WHERE id = #{p.id} AND channel_id = #{ch}")
    end
    res.json(uploads_json(channel=ch))
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

# ---------- loudness worker ----------
# One file per tick, playlist first, then the clips, then the rest of the library; a file that can't be
# decoded gets gain 0 (no tag) so it isn't retried. Measuring is ~5 s of CPU per file, hence the pacing.
loudness_todo = ref([])
loudness_checked = ref(0.)
loudness_busy = ref(false)

def loudness_candidates() =
  if list.length(library_cache()) == 0 then scan_library() end
  clips = if file.exists(time_dir) then list.map(fun (n) -> "#{time_dir}/#{n}", list.filter(is_audio, file.ls(time_dir))) else [] end
  side = list.flatten(list.map(fun (r) -> list.filter(fun (f) -> f != "", string.split(separator="\n", col(r, "tracks"))), db.query("SELECT tracks FROM channels")))
  list.append(tracks(), list.append(side, list.append(list.map(rel, list.append(jingle_files(), clips)), library_cache())))
end

def loudness_wanted() =
  loudness_on() or db_int("SELECT COUNT(*) AS n FROM channels c WHERE COALESCE((SELECT value FROM meta WHERE key = 'channel_' || c.id || '_loudness'), '1') = '1'", "n") > 0
end

thread.run(every=2., fun () -> begin
  if not loudness_busy() and loudness_wanted() then
    loudness_busy := true
    try
      if list.length(loudness_todo()) == 0 and time() - loudness_checked() > 300. then
        loudness_checked := time()
        measured = list.map(fun (r) -> col(r, "file"), db.query("SELECT file FROM loudness"))
        loudness_todo := list.filter(fun (f) -> not list.mem(f, measured), loudness_candidates())
      end
      if list.length(loudness_todo()) > 0 then
        f = list.hd(loudness_todo())
        loudness_todo := list.tl(loudness_todo())
        if db_int("SELECT COUNT(*) AS n FROM loudness WHERE file = #{sqlite.escape(f)}", "n") == 0 then
          r = request.create("replaygain:#{library}/#{f}")
          ok = request.resolve(r)
          g = if ok then tag(r, "replaygain_track_gain") else "" end
          gain = float_of_string(default=0., r/ ?dB$/i.replace(fun (_) -> "", string.trim(g)))
          db.exec("INSERT OR REPLACE INTO loudness (file, gain, at) VALUES (#{sqlite.escape(f)}, #{gain}, #{time()})")
          request.destroy(r)
        end
      end
    catch err do
      log.important("loudness: #{err.message}")
    end
    loudness_busy := false
  end
end)

# ---------- metrics ----------
# Icecast knows the listener count; everything else is read from the radio's own state.
thread.run(every=15., fun () -> begin
  n = try
    body = http.get(timeout=3., "http://icecast:8000/status-json.xsl")
    found = r/"listeners":(\d+),"listenurl":"[^"]*\/radio"/.exec(body)
    int_of_string(default=0, list.assoc(default="0", 1, found))
  catch _ do 0 end
  m_listeners(float_of_int(n))
  m_live(if live_airing() then 1. else 0. end)
  m_paused(if paused() then 1. else 0. end)
  m_likes(float_of_int(db_int("SELECT COUNT(*) AS n FROM likes", "n")))
  m_reactions(float_of_int(db_int("SELECT COUNT(*) AS n FROM reactions", "n")))
  m_messages(float_of_int(db_int("SELECT COUNT(*) AS n FROM messages WHERE is_read = 0", "n")))
  m_requests(float_of_int(db_int("SELECT COUNT(*) AS n FROM requests WHERE status = 'pending'", "n")))
  m_uploads(float_of_int(db_int("SELECT COUNT(*) AS n FROM uploads WHERE status = 'pending'", "n")))
  m_measured(float_of_int(db_int("SELECT COUNT(*) AS n FROM loudness", "n")))
end)

# ---------- stats ----------
# ?days=N counts the last N days (0 = since the start). The lists are for the admin, so hidden tracks show.
def stats_json(days, ~channel=0) =
  since = if days > 0 then time() - float_of_int(days) * 86400. else 0. end
  prefix_pattern = "#{channel}:%"
  like_where = if channel == 0 then "track NOT LIKE '%:%'" else "track LIKE #{sqlite.escape(prefix_pattern)}" end
  def ranked(sql) =
    list.map(fun (r) -> begin
      f = col(r, "file")
      clean = if channel == 0 then f else string.residual(prefix="#{channel}:", f) ?? f end
      {file=clean, label=label_of(clean), n=int_of_string(col(r, "n"), default=0)}
    end, db.query(sql))
  end
  {
    days = days,
    plays = db_int("SELECT COUNT(*) AS n FROM plays WHERE channel_id = #{channel} AND at >= #{since}", "n"),
    first_play = float_of_int(db_int("SELECT CAST(COALESCE(MIN(at), 0) AS INTEGER) AS n FROM plays WHERE channel_id = #{channel}", "n")),
    likes = db_int("SELECT COUNT(*) AS n FROM likes WHERE #{like_where} AND at >= #{since}", "n"),
    reactions = db_int("SELECT COUNT(*) AS n FROM reactions WHERE #{like_where} AND at >= #{since}", "n"),
    messages = db_int("SELECT COUNT(*) AS n FROM messages WHERE channel_id = #{channel} AND at >= #{since}", "n"),
    requests = db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{channel} AND at >= #{since}", "n"),
    top_played = ranked("SELECT file, COUNT(*) AS n FROM plays WHERE channel_id = #{channel} AND at >= #{since} GROUP BY file ORDER BY n DESC, file LIMIT 10"),
    top_liked = ranked("SELECT track AS file, COUNT(*) AS n FROM likes WHERE #{like_where} AND at >= #{since} AND track != '' GROUP BY track ORDER BY n DESC, track LIMIT 10"),
    top_requested = ranked("SELECT file, COUNT(*) AS n FROM requests WHERE channel_id = #{channel} AND at >= #{since} AND file != '' GROUP BY file ORDER BY n DESC, file LIMIT 10"),
    prometheus = channel == 0 and prometheus_url != ""
  }
end

harbor.http.register(port=panel_port, method="GET", "/api/stats", fun (req, res) -> admin(req, res, fun () ->
  res.json(stats_json(int_of_string(req.query["days"], default=7), channel=requested_channel(req)))))

# A time series from Prometheus, by name (not free PromQL): q = listeners | plays, range = 1h | 6h | 24h | 7d.
harbor.http.register(port=panel_port, method="GET", "/api/stats/series", fun (req, res) -> admin(req, res, fun () -> begin
  if prometheus_url == "" or requested_channel(req) != 0 then
    res.status_code(503)
    res.json({error="PROMETHEUS_URL تنظیم نشده"})
  else
    range = req.query["range"]
    span = if range == "1h" then 3600 elsif range == "6h" then 21600 elsif range == "7d" then 604800 else 86400 end
    step = int_of_float(float_of_int(span) / 120.)
    expr = if req.query["q"] == "plays" then "increase(radio_plays_total[#{step}s])" else "max_over_time(radio_listeners[#{step}s])" end
    now = int_of_float(time())
    endpoint = "#{prometheus_url}/api/v1/query_range?query=#{url.encode(plus=false, expr)}&start=#{now - span}&end=#{now}&step=#{step}"
    try
      body = http.get(timeout=5., endpoint)
      if body == "" then error.raise(error.register("prometheus"), "empty answer") end
      res.content_type("application/json")
      res.data(body)
    catch _ do
      res.status_code(502)
      res.json({error="Prometheus در دسترس نیست"})
    end
  end
end))

# ---------- jingles and hour announcements ----------
def base_name(path) =
  list.hd(default=path, list.rev(string.split(separator="/", path)))
end

def clips_json(~channel=0) =
  clip_state = extra_clip_state()
  {
    max_bytes = clip_max_bytes,
    max_seconds = clip_max_seconds,
    manual = if channel == 0 then {name=manual_jingle_name(), active=manual_jingle_active(), remaining=max(0., manual_jingle_until() - time())}
             else clip_state(channel) end,
    jingles = list.map(fun (f) -> {name=base_name(f), size=file.size(f)}, jingle_files()),
    hours = list.init(24, fun (h) -> begin
      f = clip_of_hour(h)
      {hour=h, name=(if f == "" then "" else base_name(f) end), size=(if f == "" then 0 else file.size(f) end)}
    end)
  }
end

def clip_mime(name) =
  ext = string.case(lower=true, r/^.*\./.replace(fun (_) -> "", name))
  if ext == "mp3" then "audio/mpeg" elsif ext == "m4a" or ext == "aac" then "audio/mp4" elsif ext == "ogg" or ext == "oga" or ext == "opus" then "audio/ogg" elsif ext == "wav" then "audio/wav" elsif ext == "flac" then "audio/flac" else "application/octet-stream" end
end

# a clip's name never carries a path
def clip_name_ok(name) =
  name != "" and not string.contains(substring="/", name) and not string.contains(substring="\\", name) and not string.contains(substring="..", name) and is_audio(name)
end

def clip_path(kind, name) =
  if kind == "time" then "#{time_dir}/#{name}" else "#{jingle_dir}/#{name}" end
end

harbor.http.register(port=panel_port, method="GET", "/api/clips", fun (req, res) -> admin(req, res, fun () -> res.json(clips_json(channel=requested_channel(req)))))

# Play an existing jingle immediately over the current song/live stream. Only one at a time.
harbor.http.register(port=panel_port, method="POST", "/api/clips/play", fun (req, res) -> admin(req, res, fun () -> begin
  ch = requested_channel(req)
  if ch != 0 then
    try
      let json.parse (p : {name: string}) = req.body(timeout=5.)
      play = extra_clip_play()
      result = play(ch, p.name)
      if result.code > 0 then
        res.status_code(result.code)
        res.json({error=result.error})
      else res.json(clips_json(channel=ch)) end
    catch err do
      res.status_code(400)
      res.json({error=err.message})
    end
  else
  try
    let json.parse (p : {name: string}) = req.body(timeout=5.)
    path = clip_path("jingle", p.name)
    if not clip_name_ok(p.name) or not list.mem(path, jingle_files()) then
      res.status_code(404)
      res.json({error="جینگل پیدا نشد"})
    elsif manual_jingle_starting() or manual_jingle_active() then
      res.status_code(409)
      res.json({error="جینگل دیگری در حال پخش است"})
    else
      manual_jingle_starting := true
      r = request.create(path)
      if not request.resolve(r) then
        manual_jingle_starting := false
        res.status_code(400)
        res.json({error="فایل جینگل قابل پخش نیست"})
      else
        duration = request.duration(path) ?? 0.
        if duration <= 0. then
          manual_jingle_starting := false
          res.status_code(400)
          res.json({error="مدت جینگل مشخص نیست"})
        else
          manual_jingle_name := p.name
          manual_jingle_started := time()
          manual_jingle_until := manual_jingle_started() + duration + 0.25
          manual_jingle.play(r)
          manual_jingle_starting := false
          res.json(clips_json())
        end
      end
    end
  catch err do
    manual_jingle_starting := false
    res.status_code(400)
    res.json({error=err.message})
  end
  end
end))

harbor.http.register(port=panel_port, method="GET", "/api/clips/audio", fun (req, res) -> admin(req, res, fun () -> begin
  name = req.query["name"]
  path = clip_path(req.query["kind"], name)
  if clip_name_ok(name) and file.exists(path) then
    res.content_type(clip_mime(name))
    res.data(file.contents(path))
  else
    res.status_code(404)
    res.data("")
  end
end))

# Raw body = the audio file; X-Kind (jingle | time), X-Hour (time only, 0-23), X-Filename (URL-encoded).
# A time clip replaces whatever the hour had. The file is checked (decodes, not too long) before it counts.
harbor.http.register(port=panel_port, method="POST", "/api/clips/upload", fun (req, res) -> admin(req, res, fun () -> begin
  try
    body = req.body(timeout=120.)
    size = string.length(encoding="ascii", body)
    kind = hdr(req, "x-kind")
    hour = int_of_string(hdr(req, "x-hour"), default=-1)
    orig = url.decode(hdr(req, "x-filename"))
    ext = string.case(lower=true, r/^.*\./.replace(fun (_) -> "", orig))
    if not list.mem(kind, ["jingle", "time"]) or not is_audio(orig) or size <= 0 or (kind == "time" and (hour < 0 or hour > 23)) then
      res.status_code(400)
      res.json({error="فایل یا اطلاعاتش درست نیست"})
    elsif size > clip_max_bytes then
      res.status_code(413)
      res.json({error="حجم فایل بیشتر از حد مجاز است"})
    else
      dir = if kind == "time" then time_dir else jingle_dir end
      if not file.exists(dir) then file.mkdir(parents=true, dir) end
      tmp = "#{dir}/.new-#{int_of_float(time() * 1000.)}.#{ext}"
      file.write(data=body, tmp)
      secs = request.duration(tmp) ?? 0.
      probe = request.create(tmp)
      decodes = request.resolve(probe)
      if not decodes or secs <= 0. or secs > clip_max_seconds then
        file.remove(tmp)
        res.status_code(400)
        res.json({error="فایل صوتی معتبر نیست یا بیشتر از ۲ دقیقه است"})
      else
        hh = if hour < 10 then "0#{hour}" else "#{hour}" end
        final =
          if kind == "time" then
            list.iter(fun (n) -> if string.contains(prefix="#{hh}.", n) then file.remove("#{dir}/#{n}") end, file.ls(dir))
            "#{hh}.#{ext}"
          else
            n = safe_name(orig)
            if file.exists("#{dir}/#{n}") then "#{int_of_float(time())}-#{n}" else n end
          end
        stored_at = "#{dir}/#{final}"
        file.move(tmp, stored_at)
        stored_rel = rel(stored_at)
        db.exec("DELETE FROM loudness WHERE file = #{sqlite.escape(stored_rel)}")
        loudness_checked := 0.
        res.json(clips_json())
      end
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/clips/delete", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {kind: string, name: string}) = req.body(timeout=5.)
    path = clip_path(p.kind, p.name)
    if list.mem(p.kind, ["jingle", "time"]) and clip_name_ok(p.name) and file.exists(path) then
      file.remove(path)
      db.exec("DELETE FROM loudness WHERE file = #{sqlite.escape(rel(path))}")
    end
    res.json(clips_json())
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# ---------- notices (admin side) ----------
def notices_json(~channel=0) =
  rows = db.query("SELECT * FROM notices WHERE channel_id = #{channel} ORDER BY id DESC LIMIT 100")
  {time=time(), items=list.map(notice_row, rows)}
end

# the image type from the first bytes, never from the name the admin's browser sent
def image_ext(b) =
  s = fun (a, n) -> string.sub(encoding="ascii", b, start=a, length=n)
  if s(0, 3) == "\xFF\xD8\xFF" then "jpg"
  elsif s(0, 4) == "\x89PNG" then "png"
  elsif s(0, 4) == "GIF8" then "gif"
  elsif s(0, 4) == "RIFF" and s(8, 4) == "WEBP" then "webp"
  else "" end
end

def image_mime(stored) =
  ext = r/^.*\./.replace(fun (_) -> "", stored)
  if ext == "jpg" then "image/jpeg" elsif ext == "png" then "image/png" elsif ext == "gif" then "image/gif" else "image/webp" end
end

# raw body = the picture; answers the stored name that /api/notices then refers to
harbor.http.register(port=panel_port, method="POST", "/api/notices/image", fun (req, res) -> admin(req, res, fun () -> begin
  try
    body = req.body(timeout=60.)
    size = string.length(encoding="ascii", body)
    ext = image_ext(body)
    if ext == "" or size <= 0 then
      res.status_code(400)
      res.json({error="فقط عکس jpg، png، gif یا webp"})
    elsif size > notice_image_max then
      res.status_code(413)
      res.json({error="حجم عکس بیشتر از ۳ مگابایت است"})
    else
      if not file.exists(notice_dir) then file.mkdir(parents=true, notice_dir) end
      stored = "#{int_of_float(time() * 1000.)}.#{ext}"
      file.write(data=body, "#{notice_dir}/#{stored}")
      res.json({image=stored})
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# public: the picture of a notice (port 8000 proxies this path)
harbor.http.register(port=panel_port, method="GET", "/api/notice/image", fun (req, res) -> begin
  wanted = int_of_string(req.query["id"], default=0)
  rows = db.query("SELECT image FROM notices WHERE image != '' AND id = #{wanted}")
  stored = if list.length(rows) > 0 then col(list.hd(rows), "image") else "" end
  if stored != "" and file.exists("#{notice_dir}/#{stored}") then
    res.content_type(image_mime(stored))
    res.header("Cache-Control", "public, max-age=86400")
    res.header("X-Content-Type-Options", "nosniff")
    res.data(file.contents("#{notice_dir}/#{stored}"))
  else
    res.status_code(404)
    res.data("")
  end
end)

harbor.http.register(port=panel_port, method="GET", "/api/notices", fun (req, res) -> admin(req, res, fun () -> res.json(notices_json(channel=requested_channel(req)))))

# {title, body, style (banner | popup), ttl (seconds, 0 = until ended), image (a stored name or ""), reply_to (message id or 0)}
# A reply publishes the message it answers (with the name the listener typed, if any) next to the answer.
harbor.http.register(port=panel_port, method="POST", "/api/notices", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {title: string, body: string, style: string, ttl: int, image: string, reply_to: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    title = string.trim(p.title)
    body = string.trim(p.body)
    now = time()
    quoted = if p.reply_to > 0 then db.query("SELECT name, body FROM messages WHERE id = #{p.reply_to} AND channel_id = #{ch}") else [] end
    has_quote = list.length(quoted) > 0
    quote_name = if has_quote and col(list.hd(quoted), "name") != "" then col(list.hd(quoted), "name") elsif has_quote then "یک شنونده" else "" end
    quote_text = if has_quote then col(list.hd(quoted), "body") else "" end
    image_ok = p.image == "" or (r/^[0-9]+\.(jpg|png|gif|webp)$/.test(p.image) and file.exists("#{notice_dir}/#{p.image}"))
    empty = title == "" and body == "" and p.image == ""
    bad = not channel_valid(ch) or empty or string.length(title) > notice_title_max or string.length(body) > notice_body_max or not list.mem(p.style, ["banner", "popup"]) or p.ttl < 0 or p.ttl > notice_ttl_max or not image_ok or (p.reply_to > 0 and (not has_quote or body == ""))
    if bad then
      res.status_code(400)
      res.json({error="اعلان خالی است یا مقدارهایش درست نیست"})
    else
      expires = if p.ttl > 0 then now + float_of_int(p.ttl) else 0. end
      db.exec("INSERT INTO notices (title, body, quote_name, quote_text, image, style, at, expires, message_id, channel_id) VALUES (#{sqlite.escape(title)}, #{sqlite.escape(body)}, #{sqlite.escape(quote_name)}, #{sqlite.escape(quote_text)}, #{sqlite.escape(p.image)}, #{sqlite.escape(p.style)}, #{now}, #{expires}, #{p.reply_to}, #{ch})")
      id = db_int("SELECT MAX(id) AS n FROM notices", "n")
      if has_quote then db.exec("UPDATE messages SET notice_id = #{id}, is_read = 1 WHERE id = #{p.reply_to} AND channel_id = #{ch}") end
      res.json(notices_json(channel=ch))
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/notices/end", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    db.exec("UPDATE notices SET ended = #{time()} WHERE ended = 0 AND id = #{p.id} AND channel_id = #{ch}")
    res.json(notices_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

harbor.http.register(port=panel_port, method="POST", "/api/notices/delete", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {id: int}) = req.body(timeout=5.)
    ch = requested_channel(req)
    rows = db.query("SELECT image FROM notices WHERE id = #{p.id} AND channel_id = #{ch}")
    if list.length(rows) > 0 then
      img = col(list.hd(rows), "image")
      db.exec("DELETE FROM notices WHERE id = #{p.id} AND channel_id = #{ch}")
      db.exec("UPDATE messages SET notice_id = COALESCE((SELECT MAX(id) FROM notices WHERE message_id = messages.id), 0) WHERE notice_id = #{p.id}")
      shared = img != "" and db_int("SELECT COUNT(*) AS n FROM notices WHERE image = #{sqlite.escape(img)}", "n") > 0
      if img != "" and not shared and file.exists("#{notice_dir}/#{img}") then file.remove("#{notice_dir}/#{img}") end
    end
    res.json(notices_json(channel=ch))
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
end))

# hourly: a picture that no notice uses (an upload the admin never published) goes after an hour
thread.run(every=3600., fun () -> begin
  if file.exists(notice_dir) then
    used = list.map(fun (r) -> begin
      img = col(r, "image")
      "#{notice_dir}/#{img}"
    end, db.query("SELECT image FROM notices WHERE image != ''"))
    list.iter(fun (f) -> begin
      stamp = float_of_string(default=0., r/\..*$/.replace(fun (_) -> "", base_name(f))) / 1000.
      if not list.mem(f, used) and time() - stamp > 3600. then file.remove(f) end
    end, file.ls(absolute=true, notice_dir))
  end
end)

harbor.http.register(port=panel_port, method="GET", "/api/library", fun (req, res) -> admin(req, res, fun () -> begin
  if req.query["refresh"] != "" or list.length(library_cache()) == 0 then scan_library() end
  res.json(library_cache())
end))

harbor.http.register(port=panel_port, method="GET", "/api/notes", fun (req, res) -> admin(req, res, fun () -> begin
  f = req.query["file"]
  if not valid(f) then
    res.status_code(400)
    res.json({error="آهنگ پیدا نشد"})
  else res.json(note_of(f)) end
end))

harbor.http.register(port=panel_port, method="POST", "/api/notes", fun (req, res) -> admin(req, res, fun () -> begin
  try
    let json.parse (p : {file: string, description: string, facts: string}) = req.body(timeout=5.)
    f = p.file
    description = string.trim(p.description)
    facts = string.trim(p.facts)
    if not valid(f) or string.length(description) > 2000 or string.length(facts) > 2000 then
      res.status_code(400)
      res.json({error="آهنگ پیدا نشد یا متن بیش از حد بلند است"})
    else
      if description == "" and facts == "" then
        db.exec("DELETE FROM notes WHERE track = #{sqlite.escape(f)}")
      else
        db.exec("INSERT OR REPLACE INTO notes (track, description, facts) VALUES (#{sqlite.escape(f)}, #{sqlite.escape(description)}, #{sqlite.escape(facts)})")
      end
      res.json(note_of(f))
    end
  catch err do
    res.status_code(400)
    res.json({error=err.message})
  end
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

# Players read the stream's own metadata, which is only sent when a track starts: re-send it when the track
# on air on channel 0 is hidden or shown, whichever channel's panel did it.
def refresh_main_hidden(f) =
  m = current()
  if rel(m["filename"]) == f and not live_airing() then
    meta_in.insert_metadata(new_track=false,
      if is_hidden(f) then [("title", hidden_title)] else [("title", m["title"]), ("artist", m["artist"])] end)
  end
end

api("hidden", fun (body) -> begin
  let json.parse (p : {file: string, hidden: bool}) = body
  if p.hidden then
    if valid(p.file) and not list.mem(p.file, hidden()) then hidden := list.append(hidden(), [p.file]) end
  else
    hidden := list.filter(fun (x) -> x != p.file, hidden())
  end
  save_hidden()
  refresh_main_hidden(p.file)
  refresh = extra_hidden_refresh()
  refresh(p.file)
end)

api("live/allow", fun (body) -> begin
  let json.parse (p : {allowed: bool}) = body
  live_allowed := p.allowed
end)

harbor.http.register(port=panel_port, method="POST", "/api/live/token", fun (req, res) -> admin(req, res, fun () ->
  begin
    ch = requested_channel(req)
    if channel_valid(ch) then res.json({token=if ch == 0 then live_token() else channel_live_token(ch) end, port=live_port, mount=if ch == 0 then "live" else "live-#{ch}" end})
    else res.status_code(404); res.json({token="", port=0, mount=""}) end
  end))

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

# ---------- additional channels ----------
# An output is created for each channel and shut down when it is deleted. The main /radio output above
# keeps its existing state and API. Extra channels use a separate playlist, queue, clock and Icecast mount.
channels = ref([])
channel_limit = max_channels - 1

def channel_name_ok(name) =
  name != "" and string.length(name) <= 60 and not string.contains(substring="\n", name) and not string.contains(substring="\r", name)
end

def channel_rows() =
  {id=0, name=meta_get("main_channel_name", "رادیو")} :: list.map(fun (c) -> {id=c.id, name=c.name() ?? ""}, channels())
end

def channel_track(f) =
  t = file_tags(f)
  p = public_track(f, fst(t), snd(t))
  {file=p.file, title=p.title, artist=p.artist}
end

def channel_now(c) =
  m = c.current()
  f = rel(m["filename"])
  now = public_track(f, m["title"], m["artist"])
  n = list.length(c.tracks())
  queued = list.map(fun (r) -> rel(request.filename(r)), list.filter(fun (r) -> tag(r, "radio_kind") == "", c.source.queue()))
  predicted = if c.mode() == "normal" and n > 0 then list.init(5, fun (i) -> list.nth(c.tracks(), (c.cursor() + i) mod n)) else [] end
  candidates = list.append(queued, list.append(c.next(), predicted))
  coming = list.prefix(5, list.fold(fun (acc, x) -> if list.mem(x, acc) then acc else list.append(acc, [x]) end, [], candidates))
  {
    id=c.id, name=c.name(), mount="/channel-#{c.id}", paused=c.paused(), mode=c.mode(),
    now={file=now.file, title=now.title, artist=now.artist, elapsed=c.source.elapsed(), duration=c.source.duration()},
    upcoming=list.map(channel_track, coming),
    history=list.map(fun (h) -> begin
      p = public_track(h.file, h.title, h.artist)
      {file=p.file, title=p.title, artist=p.artist, at=h.at}
    end, list.prefix(6, c.history()))
  }
end

def channel_live_status(c) =
  live_connected = null.get(c?.live_connected)
  live_allowed = null.get(c?.live_allowed)
  live_since = null.get(c?.live_since)
  live_title = null.get(c?.live_title)
  live_client = null.get(c?.live_client)
  live_feed = null.get(c?.live_feed)
  live_input = null.get(c?.live_input)
  connected = live_connected()
  {allowed=live_allowed(), connected=connected,
   airing=connected and live_allowed() and not c.paused() and live_feed.is_ready(),
   since=if connected then time() - live_since() else 0. end,
   title=live_title(), client=live_client(), buffer=live_input.buffer_length(), port=live_port}
end

def channel_listen(c, listener) =
  m = c.current()
  n = public_track(rel(m["filename"]), m["title"], m["artist"])
  all = list.filter(fun (h) -> h.channel == c.id, extra_plays())
  later = if list.length(all) > 0 then list.tl(all) else [] end
  shown = if show_recent(channel=c.id) then list.append(list.prefix(1, all), list.prefix(5, list.filter(fun (h) -> h.kind == "", later))) else list.prefix(1, all) end
  plays = list.map(fun (h) -> begin
    p = public_track(h.file, h.title, h.artist)
    key = channel_track_key(c.id, h.file)
    {id=h.id, file=p.file, title=p.title, artist=p.artist, kind=h.kind, at=h.at,
     likes=if h.kind == "" then like_count(key) else 0 end,
     liked=h.kind == "" and liked_by(listener, key)}
  end, shown)
  on = list.hd(default={id=-1, file="", title="", artist="", kind="", at=0., likes=0, liked=false}, plays)
  coming = if show_next(channel=c.id) then channel_now(c).upcoming else [] end
  note = if n.file != "" and on.kind == "" then note_of(n.file) else {description="", facts=""} end
  live = channel_live_status(c)
  {
    paused=c.paused(), time=time(),
    now={id=on.id, kind=on.kind, file=n.file, title=n.title, artist=n.artist,
         elapsed=c.source.elapsed(), duration=c.source.duration(), likes=on.likes, liked=on.liked,
         reactions=live_taps(on.id), description=note.description, facts=note.facts},
    mine=mine_requests(listener, channel=c.id), notices=notices_public(channel=c.id),
    catalog_open=catalog_public(channel=c.id),
    lists={next=show_next(channel=c.id), recent=show_recent(channel=c.id), count=5},
    next=list.hd(default={file="", title="", artist=""}, coming), upcoming=coming, history=plays,
    live={airing=live.airing, title=live.title, since=live.since}
  }
end

def channel_manage(c) =
  n = channel_now(c)
  {id=n.id, name=n.name, mount=n.mount, paused=n.paused, mode=n.mode, now=n.now,
   upcoming=n.upcoming, history=n.history, tracks=c.tracks(), next=c.next()}
end

def main_manage() =
  m = current()
  {id=0, name=meta_get("main_channel_name", "رادیو"), mount="/radio", paused=paused(), mode=mode(),
   now={file=rel(m["filename"]), title=m["title"], artist=m["artist"], elapsed=auto.elapsed(), duration=auto.duration()},
   upcoming=upcoming_list(5),
   history=list.map(fun (h) -> {file=h.file, title=h.title, artist=h.artist, at=h.at}, list.prefix(6, history())),
   tracks=tracks(), next=upcoming()}
end

def channels_manage() =
  main_manage() :: list.map(channel_manage, channels())
end

def channel_status(c) =
  m = c.current()
  f = rel(m["filename"])
  prefix = "#{c.id}:"
  pattern = "#{prefix}%"
  likes = list.map(fun (r) -> {
    file=string.residual(prefix=prefix, col(r, "track")) ?? "",
    n=int_of_string(col(r, "n"), default=0)
  }, db.query("SELECT track, COUNT(*) AS n FROM likes WHERE track LIKE #{sqlite.escape(pattern)} GROUP BY track"))
  {
    mode=c.mode(), paused=c.paused(), next_index=(-1),
    now={file=f, title=m["title"], artist=m["artist"], elapsed=c.source.elapsed(), duration=c.source.duration()},
    tracks=c.tracks(), queue=c.next(),
    live=channel_live_status(c),
    hidden=hidden(), hidden_title=hidden_title, likes=likes, reactions=reaction_counts(channel_track_key(c.id, f)),
    messages_unread=db_int("SELECT COUNT(*) AS n FROM messages WHERE channel_id = #{c.id} AND is_read = 0", "n"),
    requests_pending=db_int("SELECT COUNT(*) AS n FROM requests WHERE channel_id = #{c.id} AND status = 'pending'", "n"),
    uploads_pending=db_int("SELECT COUNT(*) AS n FROM uploads WHERE channel_id = #{c.id} AND status = 'pending'", "n")
  }
end

def channel_follow_on_air(c, files) =
  cursor_set = null.get(c?.cursor_set)
  m = c.current()
  f = rel(m["filename"])
  cursor_set(0)
  list.iteri(fun (i, e) -> if e == f then cursor_set(i + 1) end, files)
end

def channel_save(c) =
  lines = string.concat(separator="\n", c.tracks())
  safe_name = c.name() ?? ""
  db.exec("UPDATE channels SET name = #{sqlite.escape(safe_name)}, tracks = #{sqlite.escape(lines)}, mode = #{sqlite.escape(c.mode())}, paused = #{if c.paused() then 1 else 0 end}, cursor = #{c.cursor()} WHERE id = #{c.id}")
end

def channel_reset_queue(c, ~list_changed=false) =
  version = null.get(c?.version)
  version_set = null.get(c?.version_set)
  next_set = null.get(c?.next_set)
  cursor_set = null.get(c?.cursor_set)
  bag = null.get(c?.bag)
  bag_set = null.get(c?.bag_set)
  version_set(version() + 1)
  list.iter(fun (r) -> begin
    from = tag(r, "radio_from")
    i = int_of_string(tag(r, "radio_index"), default=-1)
    if tag(r, "radio_kind") == "" then
      if from == "next" then next_set(rel(request.filename(r)) :: c.next())
      elsif not list_changed and from == "normal" and i >= 0 then cursor_set(i)
      elsif not list_changed and from == "randomize" and i >= 0 then bag_set(i :: bag()) end
    end
  end, list.rev(c.source.queue()))
  c.source.set_queue([])
  version_set(version() + 1)
end

def channel_equalize(s, gain, set_setters) =
  def mkfilter(graph) =
    def band(input, frequency, i) =
      f = ffmpeg.filter.equalizer.create(frequency=frequency, width_type=3, width=1., gain=gain(i), graph)
      f.set_input(input)
      (f.output, fun (db) -> ignore(f.process_command("gain", "#{db}")))
    end
    let {audio = original} = source.tracks(s)
    a = ffmpeg.filter.audio.input(graph, original)
    let (a, set0) = band(a, 60., 0)
    let (a, set1) = band(a, 150., 1)
    let (a, set2) = band(a, 400., 2)
    let (a, set3) = band(a, 1000., 3)
    let (a, set4) = band(a, 2500., 4)
    let (a, set5) = band(a, 6000., 5)
    let (a, set6) = band(a, 12000., 6)
    set_setters([set0, set1, set2, set3, set4, set5, set6])
    a = ffmpeg.filter.audio.output(graph, a)
    source({audio=a, metadata=track.metadata(a), track_marks=track.track_marks(a)})
  end
  ffmpeg.filter.create(mkfilter)
end

def make_channel(id, name, files, play_mode, is_paused, start_cursor) =
  c_name = ref(name)
  c_tracks = ref(list.filter(valid, files))
  c_mode = ref(if list.mem(play_mode, ["normal", "randomize", "random"]) then play_mode else "normal" end)
  c_paused = ref(is_paused)
  c_cursor = ref(start_cursor)
  c_next = ref([])
  c_bag = ref([])
  c_current = ref([])
  c_history = ref([])
  c_version = ref(0)
  c_air_end = ref(0.)
  c_last_hour = ref(time.local(time()).hour)
  c_since_jingle = ref(0)
  c_eq_enabled = ref(channel_meta_get(id, "eq_enabled", "0") == "1")
  c_eq_gains = ref(list.map(fun (i) -> float_of_string(channel_meta_get(id, "eq_#{i}", "0"), default=0.), [0, 1, 2, 3, 4, 5, 6]))
  c_eq_setters = ref([])
  def c_eq_gain(i) = if c_eq_enabled() then list.nth(c_eq_gains(), i) else 0. end end
  def c_eq_update(enabled, gains) =
    c_eq_enabled := enabled
    c_eq_gains := gains
    list.iteri(fun (i, set_gain) -> set_gain(c_eq_gain(i)), c_eq_setters())
  end
  c_jingle = request.player(simultaneous=false)
  c_jingle_name = ref("")
  c_jingle_until = ref(0.)
  c_jingle_starting = ref(false)
  c_duck_level = ref(1.)
  c_duck_tick = ref(time())
  def c_jingle_state() =
    remaining = max(0., c_jingle_until() - time())
    {name=c_jingle_name(), active=remaining > 0., remaining=remaining}
  end
  def c_duck_gain() =
    now = time()
    delta = max(0., min(0.1, now - c_duck_tick()))
    c_duck_tick := now
    target = if c_jingle_state().active then 0.28 else 1. end
    step = if target < c_duck_level() then delta * 0.72 / 0.35 else delta * 0.72 / 0.7 end
    c_duck_level := if target < c_duck_level() then max(target, c_duck_level() - step) else min(target, c_duck_level() + step) end
    c_duck_level()
  end
  def c_jingle_play(name) =
    path = clip_path("jingle", name)
    if not clip_name_ok(name) or not list.mem(path, jingle_files()) then {code=404, error="جینگل پیدا نشد"}
    elsif c_jingle_starting() or c_jingle_state().active then {code=409, error="جینگل دیگری در این کانال در حال پخش است"}
    else
      c_jingle_starting := true
      try
        r = request.create(path)
        duration = request.duration(path) ?? 0.
        if not request.resolve(r) or duration <= 0. then {code=400, error="فایل جینگل قابل پخش نیست"}
        else
          c_jingle_name := name
          c_jingle_until := time() + duration + 0.25
          c_jingle.play(r)
          {code=0, error=""}
        end
      finally c_jingle_starting := false end
    end
  end
  c_live_allowed = ref(true)
  c_live_connected = ref(false)
  c_live_since = ref(0.)
  c_live_title = ref("")
  c_live_client = ref("")
  def channel_auth(credentials) =
    token = list.mem((id, credentials.password), extra_live_tokens())
    extra_live_tokens := list.filter(fun (x) -> x != (id, credentials.password), extra_live_tokens())
    c_live_allowed() and credentials.password != "" and (credentials.password == live_password or token)
  end
  c_live = input.harbor(id="channel_live_#{id}", "live-#{id}", port=live_port, auth=channel_auth,
    buffer=live_buffer_seconds, max=live_buffer_seconds + 2.,
    on_connect=fun (h) -> begin
      c_live_connected := true
      c_live_since := time()
      c_live_title := ""
      c_live_client := h["User-Agent"]
    end,
    on_disconnect=fun () -> begin c_live_connected := false; c_live_title := "" end)
  c_live.on_metadata(fun (m) -> if m["title"] != "" then c_live_title := m["title"] end)
  c_live_feed = buffer(id="channel_live_feed_#{id}", buffer=crossfade_seconds + 0.5, max=crossfade_seconds + 3., c_live)
  def c_special() =
    start = if c_air_end() > time() then c_air_end() else time() end
    hour = time.local(start).hour
    announce = channel_meta_get(id, "time_announce", "0") == "1"
    hit = if announce and hour != c_last_hour() then clip_of_hour(hour) else "" end
    if hit == "" and hour != c_last_hour() then c_last_hour := hour end
    jingles = jingle_files()
    every = int_of_string(channel_meta_get(id, "jingle_every", "0"), default=0)
    if hit != "" then
      c_last_hour := hour
      null(clip_request_channel(id, hit, "time", "🕐 ساعت #{list.nth(fa_hours, hour)}"))
    elsif every > 0 and c_since_jingle() >= every and list.length(jingles) > 0 then
      c_since_jingle := 0
      null(clip_request_channel(id, list.nth(jingles, random.int(min=0, max=list.length(jingles))), "jingle", "🎙 رادیو"))
    else null() end
  end
  def rec choose_track() =
    v = c_version()
    n = list.length(c_tracks())
    from_next = list.length(c_next()) > 0
    if not from_next and n == 0 then null()
    else
      i = if from_next then -1
          elsif c_mode() == "random" then random.int(min=0, max=n)
          elsif c_mode() == "randomize" then
            if list.length(c_bag()) == 0 then c_bag := list.shuffle(list.init(n, fun (x) -> x)) end
            list.hd(c_bag())
          else c_cursor() mod n end
      f = if from_next then list.hd(c_next()) else list.nth(c_tracks(), i) end
      r = track_request_channel(id, f, if from_next then "radio_from=\"next\"" else "radio_from=\"#{c_mode()}\",radio_index=\"#{i}\"" end)
      ok = request.resolve(r)
      if c_version() != v then choose_track()
      else
        if from_next then c_next := list.tl(c_next())
        elsif c_mode() == "randomize" then c_bag := list.tl(c_bag())
        elsif c_mode() == "normal" then c_cursor := i + 1 end
        if ok then null(r) else null() end
      end
    end
  end
  def choose() =
    clip = if list.length(c_tracks()) > 0 or list.length(c_next()) > 0 then c_special() else null() end
    clip_ok = if null.defined(clip) then request.resolve(null.get(clip)) else false end
    if clip_ok then clip
    else
      r = choose_track()
      if null.defined(r) then c_since_jingle := c_since_jingle() + 1 end
      r
    end
  end
  src = request.dynamic(id="channel_#{id}", retry_delay=2., choose)
  src.on_track(fun (m) -> begin
    c_current := m
    f = rel(m["filename"])
    kind = m["radio_kind"]
    c_air_end := time() + (request.duration(m["filename"]) ?? 0.)
    play_seq := play_seq() + 1
    h = {id=play_seq(), channel=id, file=f, title=m["title"], artist=m["artist"], kind=kind, at=time()}
    c_history := list.prefix(12, h :: c_history())
    extra_plays := list.prefix(100, h :: extra_plays())
    if kind == "" then
      db.exec("INSERT INTO plays (file, at, channel_id) VALUES (#{sqlite.escape(f)}, #{time()}, #{id})")
      db.exec("UPDATE requests SET status = 'played', done_at = #{time()} WHERE channel_id = #{id} AND status = 'queued' AND file = #{sqlite.escape(f)}")
      db.exec("UPDATE channels SET cursor = #{c_cursor()} WHERE id = #{id}")
    end
  end)
  level = limit(id="channel_limit_#{id}", threshold=-1., replaygain(id="channel_gain_#{id}", src))
  on_air = switch(id="channel_on_air_#{id}", track_sensitive=false, [({c_live_allowed()}, c_live_feed), ({true}, level)])
  switched = switch(id="channel_switch_#{id}", track_sensitive=false, [({not c_paused()}, on_air), ({true}, blank(id="channel_blank_#{id}"))])
  signal = crossfade(id="channel_fade_#{id}", duration=crossfade_seconds, fade_in=crossfade_seconds, fade_out=crossfade_seconds, switched)
  signal = add(id="channel_manual_jingle_mix_#{id}", normalize=false, [amplify(id="channel_jingle_duck_#{id}", override=null(), fun () -> c_duck_gain(), signal), c_jingle])
  signal = ffmpeg.raw.decode.audio(channel_equalize(ffmpeg.raw.encode.audio(%ffmpeg(%audio.raw), signal), c_eq_gain, fun (setters) -> c_eq_setters := setters))
  signal = limit(id="channel_eq_peak_#{id}", threshold=-1., signal)
  signal_in = insert_metadata(signal)
  signal = metadata.map(update=false, outgoing_metadata, signal_in)
  out = output.icecast(id="channel_output_#{id}", %mp3(bitrate=192), host="icecast", port=8000,
    password=environment.get("ICECAST_SOURCE_PASSWORD"), mount="/channel-#{id}", name=name,
    description="LAN Radio channel", genre="Mixed", mksafe(signal))
  {id=id, name=c_name, name_set=fun (x) -> c_name := x,
   tracks=c_tracks, tracks_set=fun (x) -> c_tracks := x,
   mode=c_mode, mode_set=fun (x) -> c_mode := x,
   paused=c_paused, paused_set=fun (x) -> c_paused := x,
   cursor=c_cursor, cursor_set=fun (x) -> c_cursor := x,
   next=c_next, next_set=fun (x) -> c_next := x,
   bag=c_bag, bag_set=fun (x) -> c_bag := x,
   current=c_current, history=c_history,
   version=c_version, version_set=fun (x) -> c_version := x,
   eq_update=c_eq_update,
   jingle_state=c_jingle_state, jingle_play=c_jingle_play,
   live_allowed=c_live_allowed, live_allowed_set=fun (x) -> c_live_allowed := x,
   live_connected=c_live_connected, live_since=c_live_since, live_title=c_live_title, live_client=c_live_client,
   live_input=c_live, live_feed=c_live_feed,
   source=src, metadata=signal_in, output=out}
end

def channel_get(id) =
  list.filter(fun (c) -> c.id == id, channels())
end

list.iter(fun (r) -> begin
  id = int_of_string(col(r, "id"), default=0)
  files = string.split(separator="\n", col(r, "tracks"))
  c = make_channel(id, col(r, "name"), files, col(r, "mode"), col(r, "paused") == "1", int_of_string(col(r, "cursor"), default=0))
  channels := list.append(channels(), [c])
end, db.query("SELECT id, name, tracks, mode, paused, cursor FROM channels ORDER BY id"))

harbor.http.register(port=panel_port, method="GET", "/api/channels", fun (_, res) -> res.json(channel_rows()))
harbor.http.register(port=panel_port, method="GET", "/api/channels/now", fun (req, res) -> begin
  res.header("Content-Type", "application/json; charset=utf-8")
  id = int_of_string(req.query["id"], default=0)
  hit = channel_get(id)
  if list.length(hit) > 0 then res.data(json.stringify(channel_now(list.hd(hit))))
  else res.status_code(404); res.data(json.stringify({error="کانال پیدا نشد"})) end
end)
harbor.http.register(port=panel_port, method="GET", "/api/channels/listen", fun (req, res) -> begin
  id = requested_channel(req)
  hit = channel_get(id)
  if list.length(hit) > 0 then
    listener = req.query["listener"]
    res.json(channel_listen(list.hd(hit), if valid_listener(listener) then listener else "" end))
  else
    res.status_code(404)
    res.data("{}")
  end
end)
harbor.http.register(port=panel_port, method="GET", "/api/channels/manage", fun (req, res) -> admin(req, res, fun () ->
  res.json(channels_manage())))

harbor.http.register(port=panel_port, method="GET", "/api/channels/limits", fun (req, res) -> admin(req, res, fun () ->
  res.json({max_channels=max_channels})))

harbor.http.register(port=panel_port, method="POST", "/api/channels/create", fun (req, res) -> admin(req, res, fun () -> begin
  res.header("Content-Type", "application/json; charset=utf-8")
  try
    let json.parse (p : {name: string}) = req.body(timeout=5.)
    name = string.trim(p.name)
    if not channel_name_ok(name) then
      res.status_code(400)
      res.data(json.stringify({error="نام کانال نامعتبر است"}))
    elsif list.length(channels()) >= channel_limit then
      res.status_code(400)
      res.data(json.stringify({error="ظرفیت #{max_channels} کانال (شامل کانال اصلی) پر شده است"}))
    else
      db.exec("INSERT INTO channels (name, tracks, mode, paused, cursor, created) VALUES (#{sqlite.escape(name)}, '', 'normal', 0, 0, #{time()})")
      id = db_int("SELECT MAX(id) AS n FROM channels", "n")
      try
        c = make_channel(id, name, [], "normal", false, 0)
        channels := list.append(channels(), [c])
        res.data(json.stringify(channels_manage()))
      catch err do
        db.exec("DELETE FROM channels WHERE id = #{id}")
        error.raise(error.register("channel"), err.message)
      end
    end
  catch err do
    res.status_code(400)
    res.data(json.stringify({error=err.message}))
  end
end))

# One action endpoint keeps all channel playback controls behind the panel login.
harbor.http.register(port=panel_port, method="POST", "/api/channels/action", fun (req, res) -> admin(req, res, fun () -> begin
  res.header("Content-Type", "application/json; charset=utf-8")
  try
    let json.parse (p : {id: int, action: string, name: string, file: string, mode: string, paused: bool, tracks: [string]}) = req.body(timeout=5.)
    hit = channel_get(p.id)
    if p.id == 0 then
      if p.action == "rename" then
        name = string.trim(p.name)
        if not channel_name_ok(name) then error.raise(error.register("channel"), "نام کانال نامعتبر است") end
        meta_set("main_channel_name", name)
      elsif p.action == "tracks" then
        if list.length(p.tracks) > 500 or list.length(list.filter(fun (f) -> not list.mem(f, tracks()) and not valid(f), p.tracks)) > 0 then
          error.raise(error.register("channel"), "فهرست نامعتبر است")
        end
        touch(); tracks := p.tracks; save_playlist(); give_back(list_changed=true); touch(); auto.set_queue([])
      elsif p.action == "mode" then
        if not list.mem(p.mode, ["normal", "randomize", "random"]) then error.raise(error.register("channel"), "حالت نامعتبر است") end
        touch(); give_back(); mode := p.mode; bag := []; save_state(); touch(); auto.set_queue([])
      elsif p.action == "pause" then
        paused := p.paused; save_state()
      elsif p.action == "skip" then
        paused := false; save_state(); auto.skip()
      elsif p.action == "next" then
        if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
        play_next(p.file)
      elsif p.action == "play" then
        if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
        r = track_request(p.file, "radio_from=\"play\"")
        if not request.resolve(r) then error.raise(error.register("channel"), "فایل پخش نشد") end
        touch(); give_back(); paused := false; save_state(); touch(); auto.set_queue([r]); auto.skip()
      else
        error.raise(error.register("channel"), "عملیات نامعتبر است")
      end
      res.data(json.stringify(channels_manage()))
    elsif list.length(hit) == 0 then
      res.status_code(404)
      res.data(json.stringify({error="کانال پیدا نشد"}))
    else
      c = list.hd(hit)
      if p.action == "delete" then
        c.output.shutdown()
        live_input = null.get(c?.live_input)
        live_input.shutdown()
        # the buffer behind the live input keeps the input's own clock ticking after shutdown: stop the clock
        clock(live_input.clock).stop()
        channels := list.filter(fun (x) -> x.id != c.id, channels())
        db.exec("DELETE FROM channels WHERE id = #{c.id}")
        # its waiting uploads would hold the shared quota for a week; its settings and notices go with it
        list.iter(fun (r) -> begin
          stored = col(r, "stored")
          if file.exists(upload_path(stored)) then file.remove(upload_path(stored)) end
        end, db.query("SELECT stored FROM uploads WHERE channel_id = #{c.id} AND status = 'pending'"))
        db.exec("UPDATE uploads SET status = 'rejected' WHERE channel_id = #{c.id} AND status = 'pending'")
        db.exec("UPDATE notices SET ended = #{time()} WHERE channel_id = #{c.id} AND ended = 0")
        prefix = "channel_#{c.id}_"
        db.exec("DELETE FROM meta WHERE substr(key, 1, #{string.length(prefix)}) = #{sqlite.escape(prefix)}")
      elsif p.action == "rename" then
        name = string.trim(p.name)
        if not channel_name_ok(name) then error.raise(error.register("channel"), "نام کانال نامعتبر است") end
        rename = null.get(c?.name_set)
        rename(name)
        channel_save(c)
      elsif p.action == "tracks" then
        if list.length(p.tracks) > 500 or list.length(list.filter(fun (f) -> not list.mem(f, c.tracks()) and not valid(f), p.tracks)) > 0 then
          error.raise(error.register("channel"), "فهرست شامل فایل نامعتبر است یا بیش از ۵۰۰ آهنگ دارد")
        end
        channel_reset_queue(c, list_changed=true)
        tracks_set = null.get(c?.tracks_set)
        bag_set = null.get(c?.bag_set)
        tracks_set(p.tracks)
        channel_follow_on_air(c, p.tracks)
        bag_set([])
        channel_save(c)
      elsif p.action == "mode" then
        if not list.mem(p.mode, ["normal", "randomize", "random"]) then error.raise(error.register("channel"), "حالت پخش نامعتبر است") end
        channel_reset_queue(c)
        mode_set = null.get(c?.mode_set)
        bag_set = null.get(c?.bag_set)
        mode_set(p.mode)
        bag_set([])
        channel_save(c)
      elsif p.action == "pause" then
        paused_set = null.get(c?.paused_set)
        paused_set(p.paused)
        channel_save(c)
      elsif p.action == "skip" then
        paused_set = null.get(c?.paused_set)
        paused_set(false)
        c.source.skip()
        channel_save(c)
      elsif p.action == "next" then
        if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
        next_set = null.get(c?.next_set)
        next_set(list.append(c.next(), [p.file]))
      elsif p.action == "play" then
        if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
        r = track_request_channel(c.id, p.file, "radio_from=\"play\"")
        if not request.resolve(r) then error.raise(error.register("channel"), "فایل پخش نشد") end
        channel_reset_queue(c)
        paused_set = null.get(c?.paused_set)
        paused_set(false)
        c.source.set_queue([r])
        c.source.skip()
        channel_save(c)
      else
        error.raise(error.register("channel"), "عملیات نامعتبر است")
      end
      res.data(json.stringify(channels_manage()))
    end
  catch err do
    res.status_code(400)
    res.data(json.stringify({error=err.message}))
  end
end))

extra_hidden_refresh := fun (file) -> list.iter(fun (c) -> begin
  cm = c.current()
  if rel(cm["filename"]) == file then
    c.metadata.insert_metadata(new_track=false,
      if is_hidden(file) then [("title", hidden_title)] else [("title", cm["title"]), ("artist", cm["artist"])] end)
  end
end, channels())

extra_enqueue := fun (id, file) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 or not valid(file) then false
  else
    c = list.hd(hits)
    next_set = null.get(c?.next_set)
    next_set(list.append(c.next(), [file]))
    true
  end
end

extra_queued := fun (id) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then []
  else
    c = list.hd(hits)
    list.append(list.map(fun (r) -> rel(request.filename(r)), list.filter(fun (r) -> tag(r, "radio_kind") == "", c.source.queue())), c.next())
  end
end

extra_status := fun (id) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then error.raise(error.register("channel"), "کانال پیدا نشد") end
  channel_status(list.hd(hits))
end

extra_eq_update := fun (id, enabled, gains) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then error.raise(error.register("channel"), "کانال پیدا نشد") end
  c = list.hd(hits)
  update = null.get(c?.eq_update)
  update(enabled, gains)
end

extra_clip_state := fun (id) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then {name="", active=false, remaining=0.}
  else
    state = null.get(list.hd(hits)?.jingle_state)
    state()
  end
end

extra_clip_play := fun (id, name) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then {code=404, error="کانال پیدا نشد"}
  else
    c = list.hd(hits)
    if list.length(c.tracks()) == 0 and not channel_live_status(c).airing then
      {code=409, error="برای پخش جینگل، ابتدا یک آهنگ یا پخش زنده در این کانال فعال کنید"}
    else
      play = null.get(c?.jingle_play)
      play(name)
    end
  end
end

extra_control := fun (id, path, body) -> begin
  hits = channel_get(id)
  if list.length(hits) == 0 then error.raise(error.register("channel"), "کانال پیدا نشد") end
  c = list.hd(hits)
  if path == "pause" then
    let json.parse (p : {paused: bool}) = body
    paused_set = null.get(c?.paused_set)
    paused_set(p.paused)
    channel_save(c)
  elsif path == "skip" then
    paused_set = null.get(c?.paused_set)
    paused_set(false)
    c.source.skip()
    channel_save(c)
  elsif path == "mode" then
    let json.parse (p : {mode: string}) = body
    if not list.mem(p.mode, ["normal", "randomize", "random"]) then error.raise(error.register("channel"), "حالت نامعتبر است") end
    channel_reset_queue(c)
    mode_set = null.get(c?.mode_set)
    bag_set = null.get(c?.bag_set)
    mode_set(p.mode)
    bag_set([])
    channel_save(c)
  elsif path == "tracks" then
    let json.parse (p : {tracks: [string]}) = body
    if list.length(p.tracks) > 500 or list.length(list.filter(fun (f) -> not list.mem(f, c.tracks()) and not valid(f), p.tracks)) > 0 then
      error.raise(error.register("channel"), "فهرست آهنگ نامعتبر است")
    end
    channel_reset_queue(c, list_changed=true)
    tracks_set = null.get(c?.tracks_set)
    bag_set = null.get(c?.bag_set)
    tracks_set(p.tracks)
    channel_follow_on_air(c, p.tracks)
    bag_set([])
    channel_save(c)
  elsif path == "next" then
    let json.parse (p : {file: string}) = body
    if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
    next_set = null.get(c?.next_set)
    next_set(list.append(c.next(), [p.file]))
  elsif path == "play" then
    let json.parse (p : {file: string, index: int}) = body
    if not valid(p.file) then error.raise(error.register("channel"), "فایل پیدا نشد") end
    r = track_request_channel(c.id, p.file, "radio_from=\"play\"")
    if not request.resolve(r) then error.raise(error.register("channel"), "فایل پخش نشد") end
    channel_reset_queue(c)
    if p.index >= 0 and c.mode() == "normal" then
      cursor_set = null.get(c?.cursor_set)
      cursor_set(p.index + 1)
    end
    paused_set = null.get(c?.paused_set)
    paused_set(false)
    c.source.set_queue([r])
    c.source.skip()
    channel_save(c)
  elsif path == "queue/clear" then
    channel_reset_queue(c)
    next_set = null.get(c?.next_set)
    next_set([])
  elsif path == "hidden" then
    let json.parse (p : {file: string, hidden: bool}) = body
    if p.hidden then
      if valid(p.file) and not list.mem(p.file, hidden()) then hidden := list.append(hidden(), [p.file]) end
    else
      hidden := list.filter(fun (x) -> x != p.file, hidden())
    end
    save_hidden()
    refresh_main_hidden(p.file)
    refresh = extra_hidden_refresh()
    refresh(p.file)
  elsif path == "live/allow" then
    let json.parse (p : {allowed: bool}) = body
    live_allowed_set = null.get(c?.live_allowed_set)
    live_allowed_set(p.allowed)
  else
    error.raise(error.register("channel"), "این کنترل هنوز برای کانال فعال نیست")
  end
end
