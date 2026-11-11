extends SceneTree
## Builds a texture-override PCK with downscaled (and optionally VRAM-compressed) copies of
## every 2D texture in a Slay the Spire 2 port PCK.
##
## Godot's .ctex header stores the texture's *logical* size separately from the pixel
## payload, and CompressedTexture2D always applies it with texture_set_size_override().
## So we keep the header (logical size) untouched and only shrink the payload: every
## Sprite, atlas region, Spine attachment and UI layout still sees the original size,
## but the GPU (shared system RAM on these devices) holds scale^2 as many pixels.
##
## Run through tools/make-lowres.sh, or directly:
##   godot --headless --path tools/lowres --script lowres.gd -- \
##       --pck sts2.pck --out slaylowres.pck [--scale 0.5] [--min-size 256] [--max-size 0]
##       [--lossless astc|etc2|keep] [--jobs N] [--exclude 'res://images/ui/*,...'] [--dry-run]

const DATA_FORMAT_IMAGE := 0
const DATA_FORMAT_PNG := 1
const DATA_FORMAT_WEBP := 2
const FORMAT_BIT_HAS_MIPMAPS := 1 << 23
const PACK_DIR_ENCRYPTED := 1
const PACK_FILE_ENCRYPTED := 1
const PACK_FILE_REMOVAL := 2
const HEADER_SIZE := 36

var opt := {
	"pck": "",
	"out": "",
	"scale": 0.5,
	"min_size": 256,
	"max_size": 0,
	"lossless": "astc",
	"jobs": 0,
	"exclude": "",
	"dry_run": false,
	"verbose": false,
}

var _targets: Array = []
var _ctex_to_src := {}
var _excludes := PackedStringArray()
var _results: Array = []
var _mutex := Mutex.new()
var _done := 0
var _tmp_dir := ""
var _t0 := 0


func _init() -> void:
	quit(_main())


func _main() -> int:
	if not _parse_args():
		return 2
	_t0 = Time.get_ticks_msec()

	var entries := _read_pck_dir(opt.pck)
	if entries.is_empty():
		return 1

	for e in entries:
		if e.path.ends_with(".import"):
			_index_import_file(e)
	for e in entries:
		if e.path.begins_with("res://.godot/imported/") and e.path.ends_with(".ctex"):
			var src: String = _ctex_to_src.get(e.path, e.path)
			if _is_excluded(src):
				continue
			e["src"] = src
			_targets.append(e)
	print("PCK: %d files, %d 2D textures to consider" % [entries.size(), _targets.size()])

	if not opt.dry_run:
		_tmp_dir = opt.out + ".parts"
		DirAccess.make_dir_recursive_absolute(_tmp_dir)

	var tasks: int = opt.jobs if opt.jobs > 0 else -1
	var gid := WorkerThreadPool.add_group_task(_work, _targets.size(), tasks, true, "lowres")
	WorkerThreadPool.wait_for_group_task_completion(gid)

	return _finish()


func _parse_args() -> bool:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if not a.begins_with("--"):
			printerr("unexpected argument: " + a)
			return false
		var key := a.substr(2)
		var val := ""
		if "=" in key:
			val = key.get_slice("=", 1)
			key = key.get_slice("=", 0)
		key = key.replace("-", "_")
		if not opt.has(key):
			printerr("unknown option --" + key)
			return false
		if typeof(opt[key]) == TYPE_BOOL:
			opt[key] = val != "false" and val != "0"
		else:
			if val == "":
				i += 1
				if i >= args.size():
					printerr("missing value for --" + key)
					return false
				val = args[i]
			match typeof(opt[key]):
				TYPE_FLOAT: opt[key] = val.to_float()
				TYPE_INT: opt[key] = val.to_int()
				_: opt[key] = val
		i += 1

	if opt.pck == "" or (opt.out == "" and not opt.dry_run):
		printerr("usage: --pck <port .pck> --out <output .pck> [--scale 0.5] [--min-size 256] [--max-size 0]")
		printerr("       [--lossless astc|etc2|keep] [--jobs N] [--exclude glob,glob] [--dry-run] [--verbose]")
		return false
	if opt.scale <= 0.0 or opt.scale > 1.0:
		printerr("--scale must be in (0, 1]")
		return false
	if not opt.lossless in ["astc", "etc2", "keep"]:
		printerr("--lossless must be astc, etc2 or keep")
		return false
	for g in String(opt.exclude).split(",", false):
		_excludes.append(g.strip_edges())
	print("options: ", opt)
	return true


func _is_excluded(src: String) -> bool:
	for g in _excludes:
		if src.match(g):
			return true
	return false


# ---------------------------------------------------------------- PCK directory

func _read_pck_dir(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("cannot open " + path)
		return out
	if f.get_32() != 0x43504447:
		printerr("%s is not a standalone PCK (embedded PCKs aren't supported)" % path)
		return out
	var version := f.get_32()
	var gv := [f.get_32(), f.get_32(), f.get_32()]
	var flags := f.get_32()
	if flags & PACK_DIR_ENCRYPTED:
		printerr("encrypted PCK directories aren't supported")
		return out
	var file_base := f.get_64()
	if version == 3:
		f.seek(f.get_64())
	elif version == 2:
		for _i in 16:
			f.get_32()
	else:
		printerr("unsupported PCK version %d" % version)
		return out
	print("PCK v%d, Godot %d.%d.%d" % [version, gv[0], gv[1], gv[2]])

	var count := f.get_32()
	for _i in count:
		var buf := f.get_buffer(f.get_32())
		var z := buf.find(0)
		if z >= 0:
			buf = buf.slice(0, z)
		var p := buf.get_string_from_utf8()
		var ofs := f.get_64()
		var size := f.get_64()
		f.get_buffer(16)
		var fflags := f.get_32()
		if fflags & (PACK_FILE_ENCRYPTED | PACK_FILE_REMOVAL):
			continue
		if not p.begins_with("res://"):
			p = "res://" + p
		out.append({"path": p, "ofs": file_base + ofs, "size": size})
	return out


func _read_entry(e: Dictionary) -> PackedByteArray:
	var f := FileAccess.open(opt.pck, FileAccess.READ)
	f.seek(e.ofs)
	return f.get_buffer(e.size)


func _index_import_file(e: Dictionary) -> void:
	var src: String = e.path.trim_suffix(".import")
	for line in _read_entry(e).get_string_from_utf8().split("\n"):
		if line.begins_with("path") and ".ctex\"" in line:
			_ctex_to_src[line.get_slice("\"", 1)] = src


# ---------------------------------------------------------------- per-texture work

func _work(i: int) -> void:
	var r := _process_texture(_targets[i], i)
	_mutex.lock()
	_results.append(r)
	_done += 1
	var done := _done
	_mutex.unlock()
	if opt.verbose and r.status != "skip":
		print("%s %s %dx%d -> %dx%d %s" % [r.status, r.src, r.get("pw", 0), r.get("ph", 0), r.get("tw", 0), r.get("th", 0), r.get("why", "")])
	if done % 250 == 0 or done == _targets.size():
		print("  %d/%d (%.0fs)" % [done, _targets.size(), (Time.get_ticks_msec() - _t0) / 1000.0])


func _process_texture(e: Dictionary, idx: int) -> Dictionary:
	var r := {"path": e.path, "src": e.src, "status": "skip", "before": 0, "after": 0}
	var buf := _read_entry(e)
	if buf.size() < HEADER_SIZE + 16 or buf.slice(0, 4).get_string_from_ascii() != "GST2":
		r.why = "not a GST2 texture"
		return r

	var sp := StreamPeerBuffer.new()
	sp.data_array = buf
	sp.seek(4)
	var version := sp.get_u32()
	var lw := sp.get_u32()
	var lh := sp.get_u32()
	var flags := sp.get_u32()
	var mip_limit := sp.get_u32()
	sp.seek(HEADER_SIZE)
	var df := sp.get_u32()
	var pw := sp.get_u16()
	var ph := sp.get_u16()
	var mips := sp.get_u32()
	var fmt := sp.get_u32()
	r.pw = pw
	r.ph = ph

	if maxi(lw, lh) < opt.min_size:
		r.why = "small"
		return r
	if df != DATA_FORMAT_IMAGE and df != DATA_FORMAT_PNG and df != DATA_FORMAT_WEBP:
		r.why = "unsupported data format %d" % df
		return r

	var s: float = opt.scale
	if opt.max_size > 0:
		s = minf(s, float(opt.max_size) / maxi(lw, lh))
	var tw := mini(pw, maxi(4, roundi(lw * s)))
	var th := mini(ph, maxi(4, roundi(lh * s)))
	var lossless := df != DATA_FORMAT_IMAGE
	var convert: bool = lossless and opt.lossless != "keep"
	if tw == pw and th == ph and not convert:
		r.why = "already small enough"
		return r

	if opt.dry_run:
		var bpp_before := 4.0 if lossless else float(buf.size() - HEADER_SIZE - 16) / (pw * ph)
		var bpp_after := 1.0 if (convert or not lossless) else 4.0
		r.before = int(pw * ph * bpp_before)
		r.after = int(tw * th * bpp_after)
		r.status = "ok"
		r.tw = tw
		r.th = th
		return r

	# ---- decode
	var img: Image
	if lossless:
		var size := sp.get_u32()
		var chunk := buf.slice(sp.get_position(), sp.get_position() + size)
		img = Image.new()
		var err := img.load_png_from_buffer(chunk) if df == DATA_FORMAT_PNG else img.load_webp_from_buffer(chunk)
		if err != OK:
			r.status = "fail"
			r.why = "decode error %d" % err
			return r
	else:
		img = Image.create_from_data(pw, ph, mips > 0, fmt, buf.slice(sp.get_position()))
		if img == null or img.is_empty():
			r.status = "fail"
			r.why = "bad image data"
			return r
		if mips > 0:
			img.clear_mipmaps()

	r.before = img.get_data().size() if lossless else buf.size() - HEADER_SIZE - 16
	var compress_mode := -1
	var astc_format := Image.ASTC_FORMAT_4x4
	if img.is_compressed():
		compress_mode = _compress_mode_for(img.get_format())
		if img.get_format() in [Image.FORMAT_ASTC_8x8, Image.FORMAT_ASTC_8x8_HDR]:
			astc_format = Image.ASTC_FORMAT_8x8
		if compress_mode < 0 or img.decompress() != OK:
			r.status = "fail"
			r.why = "cannot decompress format %d" % img.get_format()
			return r
	elif convert:
		compress_mode = Image.COMPRESS_ASTC if opt.lossless == "astc" else Image.COMPRESS_ETC2

	# ---- resize
	if compress_mode >= 0:
		# Block-compressed formats want multiples of 4. UVs are normalised against the
		# logical size, so the slight non-uniform stretch is invisible.
		tw = (tw + 3) & ~3
		th = (th + 3) & ~3
	_downscale(img, tw, th)
	r.tw = tw
	r.th = th

	var want_mips := (flags & FORMAT_BIT_HAS_MIPMAPS) != 0
	if want_mips:
		img.generate_mipmaps()

	# ---- encode
	var out_df := DATA_FORMAT_IMAGE
	var payload := PackedByteArray()
	if compress_mode >= 0:
		var e2 := img.compress_from_channels(compress_mode, img.detect_used_channels(), astc_format)
		if e2 != OK:
			r.status = "fail"
			r.why = "compress error %d" % e2
			return r
	elif lossless and not want_mips:
		out_df = df
		payload = img.save_png_to_buffer() if df == DATA_FORMAT_PNG else img.save_webp_to_buffer(false)
	r.after = img.get_data().size()

	var o := StreamPeerBuffer.new()
	o.put_data("GST2".to_ascii_buffer())
	o.put_u32(version)
	o.put_u32(lw)  # logical size unchanged: this is what keeps layouts intact
	o.put_u32(lh)
	o.put_u32(flags)
	o.put_u32(mip_limit)
	o.put_u32(0)
	o.put_u32(0)
	o.put_u32(0)
	o.put_u32(out_df)
	o.put_u16(img.get_width())
	o.put_u16(img.get_height())
	o.put_u32(img.get_mipmap_count())
	o.put_u32(img.get_format())
	if out_df == DATA_FORMAT_IMAGE:
		o.put_data(img.get_data())
	else:
		o.put_u32(payload.size())
		o.put_data(payload)

	var tmp := "%s/%d.ctex" % [_tmp_dir, idx]
	var fo := FileAccess.open(tmp, FileAccess.WRITE)
	if fo == null:
		r.status = "fail"
		r.why = "cannot write " + tmp
		return r
	fo.store_buffer(o.data_array)
	fo.close()
	r.tmp = tmp
	r.status = "ok"
	return r


func _compress_mode_for(f: int) -> int:
	match f:
		Image.FORMAT_ETC:
			return Image.COMPRESS_ETC
		Image.FORMAT_ETC2_R11, Image.FORMAT_ETC2_R11S, Image.FORMAT_ETC2_RG11, Image.FORMAT_ETC2_RG11S, \
		Image.FORMAT_ETC2_RGB8, Image.FORMAT_ETC2_RGBA8, Image.FORMAT_ETC2_RGB8A1:
			return Image.COMPRESS_ETC2
		Image.FORMAT_ASTC_4x4, Image.FORMAT_ASTC_8x8:
			return Image.COMPRESS_ASTC
		Image.FORMAT_DXT1, Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_R, Image.FORMAT_RGTC_RG:
			return Image.COMPRESS_S3TC
		Image.FORMAT_BPTC_RGBA:
			return Image.COMPRESS_BPTC
	return -1


func _downscale(img: Image, tw: int, th: int) -> void:
	if img.get_width() == tw and img.get_height() == th:
		return
	if img.get_format() == Image.FORMAT_RGBA8:
		# Bleed colour into fully transparent pixels so filtering doesn't pull in the
		# (often black) garbage RGB stored there and leave dark fringes.
		img.fix_alpha_edges()
	# Box-filter halvings first (proper area averaging), then one cubic step to the exact size.
	while img.get_width() >= tw * 2 and img.get_height() >= th * 2:
		img.shrink_x2()
	if img.get_width() != tw or img.get_height() != th:
		img.resize(tw, th, Image.INTERPOLATE_CUBIC)


# ---------------------------------------------------------------- output

func _finish() -> int:
	var ok: Array = []
	var fails := 0
	var before := 0
	var after := 0
	for r in _results:
		if r.status == "ok":
			ok.append(r)
			before += r.before
			after += r.after
		elif r.status == "fail":
			fails += 1
			printerr("FAILED %s: %s" % [r.src, r.why])
	ok.sort_custom(func(a, b): return a.before - a.after > b.before - b.after)

	var lines := PackedStringArray()
	lines.append("slaylowres report  scale=%s min_size=%s max_size=%s lossless=%s" % [opt.scale, opt.min_size, opt.max_size, opt.lossless])
	lines.append("textures rewritten: %d   failed: %d   unchanged: %d" % [ok.size(), fails, _results.size() - ok.size() - fails])
	lines.append("resident texture memory if every rewritten texture were loaded at once:")
	lines.append("  before %.0f MB   after %.0f MB   (%.1fx smaller)" % [before / 1048576.0, after / 1048576.0, float(before) / maxi(after, 1)])
	lines.append("")
	lines.append("largest savings:")
	for r in ok.slice(0, 40):
		lines.append("  %7.1f MB -> %6.1f MB  %5dx%-5d -> %5dx%-5d  %s" % [r.before / 1048576.0, r.after / 1048576.0, r.pw, r.ph, r.tw, r.th, r.src])
	var report := "\n".join(lines)
	print("\n" + report)

	if opt.dry_run:
		print("\n(dry run: estimates from headers only, nothing written)")
		return 0

	var report_path: String = opt.out.get_basename() + "-report.txt"
	var rf := FileAccess.open(report_path, FileAccess.WRITE)
	if rf:
		rf.store_string(report + "\n")
		rf.close()

	var packer := PCKPacker.new()
	if packer.pck_start(opt.out) != OK:
		printerr("cannot create " + opt.out)
		return 1
	for r in ok:
		packer.add_file(r.path, r.tmp)
	if packer.flush(false) != OK:
		printerr("failed writing " + opt.out)
		return 1
	for r in ok:
		DirAccess.remove_absolute(r.tmp)
	DirAccess.remove_absolute(_tmp_dir)

	print("\nwrote %s (%.0f MB) and %s in %.0fs" % [opt.out, FileAccess.get_size(opt.out) / 1048576.0, report_path, (Time.get_ticks_msec() - _t0) / 1000.0])
	return 1 if fails > 0 and ok.is_empty() else 0
