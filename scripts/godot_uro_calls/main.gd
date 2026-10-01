extends Node

# Drives every call in addons/godot_uro against a running Uro and records what came back.
# Usage: godot --headless --path . -- --host=127.0.0.1 --port=4010 --user=adminuser --password=... --out=/abs/results.json

var pool: HTTPPool
var api: GodotUroAPI
var host := "127.0.0.1"
var port := 4000
var user := "adminuser"
var password := ""
var out_path := ""
var records: Array = []


func _arg(name: String, default: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.substr(name.length() + 3)
	return default


func _requester() -> GodotUroRequester:
	return GodotUroRequester.new(pool, host, port)


func _has_data(r: Dictionary) -> bool:
	var out = r.get("output")
	return out is Dictionary and out.get("data") is Dictionary


func _record(call: String, method: String, path: String, r: Dictionary, parsed: bool, expect: int) -> void:
	var status: int = r.get("response_code", -1)
	var ok := status == expect and (parsed or expect != 200)
	if expect == -1:
		ok = status != 200 and r.get("requester_code", -1) != GodotUroHelper.RequesterCode.OK
	records.append({
		"call": call, "method": method, "path": path, "status": status,
		"requester": GodotUroHelper.get_string_for_requester_code(r.get("requester_code", -1)),
		"parsed": parsed, "expect": expect, "pass": ok,
		"body": str(r.get("output", {})).left(300),
	})
	print("%-30s %-6s %-40s %4d %-22s parsed=%s expect=%d %s" % [
		call, method, path, status, records[-1]["requester"], str(parsed), expect, "PASS" if ok else "FAIL"])


func _ready() -> void:
	host = _arg("host", host)
	port = int(_arg("port", str(port)))
	user = _arg("user", user)
	password = _arg("password", "")
	out_path = _arg("out", "")
	pool = HTTPPool.new()
	add_child(pool)
	api = GodotUroAPI.new(null)
	await _run()
	_write()
	var failed := 0
	for rec in records:
		if not rec["pass"]:
			failed += 1
	print("%d calls, %d failed" % [records.size(), failed])
	get_tree().quit(0 if failed == 0 else 1)


func _run() -> void:
	var p := GodotUroHelper.get_api_path()
	var r: Dictionary

	# 1 registration (closed by default; the client sends its SIGNUP_API_KEY)
	var fresh := "probe_%d" % (Time.get_unix_time_from_system() as int)
	r = await api.register_async(_requester(), fresh, fresh + "@example.com", "zeta-new-pw-93", "zeta-new-pw-93", false)
	var registered := GodotUroHelper.process_session_json(r, "", "")
	_record("register", "POST", p + "/registration", r, GodotUroHelper.requester_result_is_ok(registered) and registered.get("access_token", "") != "", int(_arg("expect-register", "403")))

	# 2 sign in
	r = await api.sign_in_async(_requester(), user, password)
	var session := GodotUroHelper.process_session_json(r, "", "")
	var access: String = session.get("access_token", "")
	var renewal: String = session.get("renewal_token", "")
	_record("sign_in", "POST", p + "/session", r, GodotUroHelper.requester_result_is_ok(session) and access != "", 200)

	# 3 profile
	r = await api.get_profile_async(_requester(), access)
	_record("get_profile", "GET", p + "/profile", r, _has_data(r), 200)

	# 4 renew
	r = await api.renew_session_async(_requester(), renewal)
	var renewed := GodotUroHelper.process_session_json(r, renewal, access)
	_record("renew_session", "POST", p + "/session/renew", r, GodotUroHelper.requester_result_is_ok(renewed) and renewed.get("access_token", "") != "", 200)

	# 5-8 shards
	r = await api.get_shards_async(_requester())
	_record("get_shards", "GET", p + "/shards", r, _has_data(r) and r["output"]["data"].get("shards") is Array, 200)

	r = await api.create_shard_async(_requester(), access, {"name": "zeta shard", "map": "zeta_map", "port": 7777, "max_users": 8, "current_users": 0})
	var shard_id: String = str(r["output"]["data"].get("id", "")) if _has_data(r) else ""
	_record("create_shard", "POST", p + "/shards", r, shard_id != "", 200)

	r = await api.update_shard_async(_requester(), access, shard_id, {"current_users": 1})
	_record("update_shard", "PUT", p + "/shards/:id", r, _has_data(r), 200)

	r = await api.delete_shard_async(_requester(), access, shard_id, {})
	_record("delete_shard", "DELETE", p + "/shards/:id", r, _has_data(r), 200)

	# 9-10 public lists
	r = await api.get_avatars_async(_requester())
	_record("get_avatars", "GET", p + "/avatars", r, _has_data(r), 200)
	r = await api.get_maps_async(_requester())
	_record("get_maps", "GET", p + "/maps", r, _has_data(r), 200)

	# 11-15 dashboard avatars, then the public show of the one just made
	var preview := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	r = await api.dashboard_get_avatars_async(_requester(), access)
	_record("dashboard_get_avatars", "GET", p + "/dashboard/avatars", r, _has_data(r), 200)

	var avatar_upload := GodotUroHelper.create_content_upload_dictionary("zeta avatar", "made by the call probe", "res://fixtures/avatar.glb", preview, true)
	r = await api.dashboard_create_avatar_async(_requester(), access, avatar_upload)
	var avatar_id: String = str(r["output"]["data"].get("id", "")) if _has_data(r) else ""
	_record("dashboard_create_avatar", "POST", p + "/dashboard/avatars", r, avatar_id != "", 200)

	r = await api.dashboard_get_avatar_async(_requester(), access, avatar_id)
	_record("dashboard_get_avatar", "GET", p + "/dashboard/avatars/:id", r, _has_data(r), 200)

	r = await api.dashboard_update_avatar_async(_requester(), access, avatar_id, {"name": "zeta avatar renamed"})
	_record("dashboard_update_avatar", "PUT", p + "/dashboard/avatars/:id", r, _has_data(r), 200)

	r = await api.get_avatar_async(_requester(), avatar_id)
	_record("get_avatar", "GET", p + "/avatars/:id", r, _has_data(r), 200)

	# 16-20 dashboard maps, then the public show
	r = await api.dashboard_get_maps_async(_requester(), access)
	_record("dashboard_get_maps", "GET", p + "/dashboard/maps", r, _has_data(r), 200)

	var map_upload := GodotUroHelper.create_content_upload_dictionary("zeta map", "made by the call probe", "res://fixtures/map.scn", preview, true)
	r = await api.dashboard_create_map_async(_requester(), access, map_upload)
	var map_id: String = str(r["output"]["data"].get("id", "")) if _has_data(r) else ""
	_record("dashboard_create_map", "POST", p + "/dashboard/maps", r, map_id != "", 200)

	r = await api.dashboard_get_map_async(_requester(), access, map_id)
	_record("dashboard_get_map", "GET", p + "/dashboard/maps/:id", r, _has_data(r), 200)

	r = await api.dashboard_update_map_async(_requester(), access, map_id, {"name": "zeta map renamed"})
	_record("dashboard_update_map", "PUT", p + "/dashboard/maps/:id", r, _has_data(r), 200)

	r = await api.get_map_async(_requester(), access, map_id)
	_record("get_map", "GET", p + "/maps/:id", r, _has_data(r), 200)

	# 21-22 identity proofs, against the signed-in user's own id
	var self_id: String = session.get("user_id", "")
	r = await api.create_identity_proof_for_async(_requester(), access, self_id)
	var proof_id: String = str(r["output"].get("id", "")) if r.get("output") is Dictionary else ""
	_record("create_identity_proof", "POST", p + "/identity_proofs", r, proof_id != "", 200)

	r = await api.get_identity_proof_async(_requester(), access, proof_id)
	_record("get_identity_proof", "GET", p + "/identity_proofs/:id", r, _has_data(r), 200)

	# 23 sign out
	r = await api.sign_out_async(_requester(), access)
	_record("sign_out", "DELETE", p + "/session", r, r.get("output") is Dictionary, 200)

	# Negative control: a planted wrong path must record as failed (expect -1: anything but OK).
	var raw := await _requester().request(p + "/profilx", {}, access, {"method": HTTPClient.METHOD_GET, "encoding": "form"})
	var control := GodotUroAPI._handle_result(raw)
	_record("control_wrong_path", "GET", p + "/profilx", control, _has_data(control), -1)


func _write() -> void:
	if out_path.is_empty():
		return
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"host": host, "port": port, "records": records}, "  "))
	f.close()
