#!/usr/bin/env python3
"""Read-only address book verification.

Checks the query contract, pagination, and the destination shapes across the fleet.
Makes no writes. Password read from the tty."""
import ssl, sys, json, getpass, http.cookiejar, urllib.request, urllib.parse, urllib.error

HOSTS = sys.argv[1:]
if not HOSTS:
    sys.exit("usage: test-addressbook.py <printer-host> [more hosts...]")
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE

def b64(s):
    import base64; return base64.b64encode(s.encode()).decode()

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")

def session(host):
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                     urllib.request.HTTPCookieProcessor(jar))
    data = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(pw)}).encode()
    try:
        op.open(urllib.request.Request(f"https://{host}/LOGIN.cmd", data=data,
                headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=15).read()
    except Exception as e:
        print(f"  login failed: {e}")
    return op

def get(op, host, path):
    try:
        r = op.open(urllib.request.Request(f"https://{host}{path}"), timeout=20)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)

AB = "/addressbook/api/addressbook"

def check_contract(op, host):
    """`lang` is required; without it the device answers 400 INVALID_PARAMETER."""
    print("  contract:")
    cases = [
        ("no params",            f"{AB}"),
        ("no lang",              f"{AB}?offset=0&limit=20&fetchCount=1"),
        ("full (expected OK)",   f"{AB}?lang=en&offset=0&limit=20&fetchCount=1"),
        ("limit=100",            f"{AB}?lang=en&offset=0&limit=100&fetchCount=1"),
    ]
    for label, path in cases:
        code, body = get(op, host, path)
        note = ""
        try:
            j = json.loads(body)
            if "ContactList" in j: note = f"{len(j['ContactList'])} contacts"
            elif "Reason" in j:    note = j["Reason"]
        except Exception:
            note = body[:40].replace("\n", "")
        print(f"    {label:22} HTTP {code:4} {note}")

def fetch_all(op, host):
    """Pages until the reported total is reached."""
    contacts, offset, total, pages = [], 0, None, 0
    while True:
        code, body = get(op, host, f"{AB}?lang=en&offset={offset}&limit=20&fetchCount=1")
        if code != 200: return None, f"HTTP {code}", 0
        j = json.loads(body)
        # ContactCount is an OBJECT of per-channel totals, with the real total nested
        # inside it under the same key -- not the integer the name implies.
        cc = j.get("ContactCount")
        if total is None:
            total = cc.get("ContactCount") if isinstance(cc, dict) else (cc or 0)
        batch = j.get("ContactList") or []
        pages += 1
        if not batch: break
        contacts += batch
        offset += 20
        if len(contacts) >= (total or 0) or pages > 50: break
    return contacts, total, pages

for host in HOSTS:
    print(f"\n=== {host} ===")
    op = session(host)
    code, body = get(op, host, "/addressbook/api/addressbook-display")
    if code == 200:
        d = json.loads(body)
        on = [k for k in ("Email","Fax","IpFax","InternetFax","ServerFax","SMB","FTP","SFTP","ScanToServer")
              if d.get(k)]
        print(f"  channels enabled: {', '.join(on) or 'none'}")
    else:
        print(f"  display info: HTTP {code}")

    check_contract(op, host)

    contacts, total, pages = fetch_all(op, host)
    if contacts is None:
        print(f"  fetch: FAILED ({total})")
        continue
    print(f"  fetched {len(contacts)} of {total} reported, in {pages} page(s)"
          f" {'OK' if len(contacts) == total else '<-- MISMATCH'}")

    kinds, dest_types, no_dest, fav = {}, {}, 0, 0
    for c in contacts:
        kinds[c.get("ContactType","?")] = kinds.get(c.get("ContactType","?"),0)+1
        if c.get("Favorite"): fav += 1
        dl = c.get("DestList") or []
        if not dl: no_dest += 1
        for d in dl:
            t = d.get("DestType","?")
            dest_types[t] = dest_types.get(t,0)+1
    print(f"  kinds: {kinds}   favourites: {fav}   contacts with no destination: {no_dest}")
    print(f"  destination types: {dest_types}")

    # Detail lives under a type-named object; confirm the app can find a target for each.
    unknown = []
    for c in contacts:
        for d in (c.get("DestList") or []):
            detail_keys = [k for k in d if k not in ("DestId","DestType","OneTouchKeyId","DestFavorite")]
            if not detail_keys:
                unknown.append((c.get("DisplayName"), d.get("DestType")))
    if unknown:
        print(f"  !! {len(unknown)} destination(s) with no detail object: {unknown[:3]}")
    else:
        print("  every destination carries a detail object")

    sample = next((c for c in contacts if c.get("DestList")), None)
    if sample:
        print("  sample:", json.dumps(sample, separators=(",", ":"))[:300])
