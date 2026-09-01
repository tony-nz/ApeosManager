#!/usr/bin/env python3
"""Determines whether an ordinary user can read their OWN accounting meters without
administrator rights -- the question that decides whether an end-user quota app can
talk to the printer directly or needs a relay holding the admin credential.

Read-only: every request is a GET or a Get* SOAP operation. Nothing is created,
modified or deleted. Passwords and PINs are read from the tty; never echoed, stored,
logged or sent anywhere except the printer itself.

Usage: probe-user-quota.py <printer-host>
"""
import base64, getpass, http.cookiejar, re, ssl, sys
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

if len(sys.argv) < 2:
    sys.exit(__doc__.strip().splitlines()[-1])
HOST = sys.argv[1]

FF   = "http://www.fujifilm.com"
CMN  = f"{FF}/fb/2021/04/ssm/management/common"
ATK  = f"{FF}/fb/2021/04/ssm/management/authentication/token"
UNS  = f"{FF}/fb/2021/04/ssm/management/aaa/user"
UPATH = "/fb/2021/04/ssm/management/aaa/user"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

b64 = lambda s: base64.b64encode(s.encode()).decode()


# --- transport ---------------------------------------------------------------

def new_session():
    """An opener with its own cookie jar, so the admin and user sessions cannot
    borrow each other's authority and quietly invalidate the whole experiment."""
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                       urllib.request.HTTPCookieProcessor(jar)), jar


def login(opener, user, password):
    """/LOGIN.cmd takes NAME and PSW each Base64-encoded, and answers {"result":"0"}."""
    body = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(password)}).encode()
    req = urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        text = opener.open(req, timeout=20).read().decode("utf-8", "replace")
    except Exception as e:
        return False, f"ERROR {e}"
    ok = re.search(r'"result"\s*:\s*"?0"?', text) is not None
    return ok, text.strip()[:120]


def logout(opener):
    """Frees the device-side session; these printers allow only a few at once."""
    try:
        opener.open(urllib.request.Request(f"https://{HOST}/LOGOUT.cmd", data=b""), timeout=10)
    except Exception:
        pass


def soap(opener, inner, op="GetUserInformation", anonymous=False, token=None):
    """One SOAP call to the AAA User service. `token` is (user, password) for a
    UsernameToken header; without it the call rides on whatever cookie `opener` holds.
    `anonymous` selects the /Anonymous/ endpoint the app builds but never calls."""
    action = f"{UPATH}#{op}"
    hdr = ""
    if token:
        u, p = token
        hdr = (f'<atk:Authentication xmlns:atk="{ATK}"><atk:UsernameToken>'
               f'<atk:Username>{u}</atk:Username><atk:Password>{p}</atk:Password>'
               f'</atk:UsernameToken></atk:Authentication>')
    env = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
           f'<soap:Header>{hdr}<MessageInformation>'
           f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
           f'<MessageType>Request</MessageType><Action>{action}</Action>'
           f'</MessageInformation></soap:Header>'
           f'<soap:Body><o:{op} xmlns:o="{UNS}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body>'
           f'</soap:Envelope>')
    segment = "Anonymous/Aaa/User" if anonymous else "Aaa/User"
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/{segment}", data=env.encode(),
                                 headers={"Content-Type": "text/xml;charset=UTF-8",
                                          "SOAPAction": action})
    try:
        r = opener.open(req, timeout=25)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)


# --- request fragments -------------------------------------------------------

PAGE  = 50
scope = lambda off, lim=PAGE: f'<o:Scope><cmn:Offset>{off}</cmn:Offset><cmn:Limit>{lim}</cmn:Limit></o:Scope>'
SCOPE = scope(0)
TYPES = '<o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>'
SORT  = '<o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>'

# Responds paths are relative to each User, not to the document root -- the prefixed
# form silently selects nothing and returns HTTP 200 with an empty result.
FIELDS = ["Authentication/UserID", "Authentication/UserType", "Authentication/UserName",
          "Accounting/Usage/#CHILD"]
RESPONDS = '<o:Responds>' + ''.join(f'<cmn:Respond>{p}</cmn:Respond>' for p in FIELDS) + '</o:Responds>'

STANDARD = TYPES + SORT + SCOPE + RESPONDS
standard = lambda off: TYPES + SORT + scope(off) + RESPONDS


def fetch_all(opener, **kw):
    """Walks the paged user collection the way the app does, returning
    (users, first_page_code, first_page_text).

    Paging is not optional: the device serves this collection in pages, so on a
    directory of more than PAGE users a single request would leave the user under
    test missing and every later case unjudgeable."""
    users, offset, total, first = [], 0, None, None
    for _ in range(200):                       # hard stop; ~10k users
        code, text = soap(opener, standard(offset), **kw)
        if first is None:
            first = (code, text)
        page = parse_users(text)
        if not page:
            break
        users += page
        m = re.search(r'NumberOfUsers[^>]*>\s*(\d+)', text)
        if m:
            total = int(m.group(1))
        offset += PAGE
        if total is not None and len(users) >= total:
            break
    code, text = first if first else (-1, "no response")
    return users, code, text


# --- parsing -----------------------------------------------------------------

def local(el):
    return el.tag.rsplit('}', 1)[-1]


def text_of(el, name):
    for d in el.iter():
        if local(d) == name and d.text and d.text.strip():
            return d.text.strip()
    return None


def parse_users(xml_text):
    """[(userID, [(type, limit, used, remaining), ...]), ...] -- or None if not XML."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None
    out = []
    for el in root.iter():
        if local(el) != "User":
            continue
        uid = text_of(el, "UserID")
        if not uid:
            continue
        meters = [(text_of(u, "Type"), text_of(u, "Limit"),
                   text_of(u, "Used"), text_of(u, "Remaining"))
                  for u in el.iter() if local(u) == "Usage"]
        out.append((uid, meters))
    return out


def fault_of(xml_text):
    if "Fault" not in xml_text:
        return None
    vals = re.findall(r'<[^>]*Value[^>]*>([^<]+)<', xml_text)
    strs = re.findall(r'<[^>]*faultstring[^>]*>([^<]+)<', xml_text)
    return " / ".join(filter(None, [vals[0] if vals else None, strs[0] if strs else None])) or "fault"


def describe(code, text, want, users=None):
    """(verdict, got_own_meters, own_record_only).

    `code`/`text` carry the transport verdict; pass `users` when the records were
    collected across several pages, so the count reflects the whole collection.

    The third value matters as much as the second: a call that hands an ordinary
    user everyone else's records has technically answered, but is a disclosure to
    report rather than a design to build on."""
    if code == -1:
        return f"ERROR {text[:60]}", False, False
    if not text.strip():
        return f"HTTP {code} empty body (usually an auth rejection)", False, False
    fault = fault_of(text)
    if fault:
        return f"HTTP {code} FAULT {fault[:60]}", False, False
    # 500 is the one non-2xx worth parsing: SOAP faults arrive with it, and one was
    # already ruled out above.
    if not (200 <= code < 300) and code != 500:
        return f"HTTP {code} {text.strip()[:50]}", False, False
    if users is None:
        users = parse_users(text)
    if users is None:
        return f"HTTP {code} non-XML, {len(text)} bytes", False, False
    if not users:
        return f"HTTP {code} OK but 0 user records", False, False
    mine = [u for u in users if u[0] == want]
    metered = [u for u in users if any(m[1] or m[2] for m in u[1])]
    note = f"HTTP {code} OK: {len(users)} user(s), {len(metered)} with meters"
    if len(users) > 1:
        note += f" -- returned OTHER USERS' records, not just {want}"
    got_own = bool(mine and any(m[1] or m[2] for m in mine[0][1]))
    return note, got_own, got_own and len(users) == 1


def show_meters(meters, indent="      "):
    if not meters:
        print(indent + "(no accounting meters on this record)")
        return
    # Sort by name only: a meter with no Type would make tuple ordering compare
    # None against str and raise.
    for t, limit, used, remaining in sorted(meters, key=lambda m: m[0] or ""):
        cap = "unlimited" if limit in (None, "9999999") else limit
        print(f"{indent}{t or '?':<12} used {used or '-':>8}  of {cap:>9}  remaining {remaining or '-':>8}")


# --- the probe ---------------------------------------------------------------

print(f"Probing {HOST} -- read-only, no records are created or changed.\n")

admin_id = input("Admin user ID [11111]: ").strip() or "11111"
admin_pw = getpass.getpass("Admin password: ")
test_id  = input("\nOrdinary user's ID to test: ").strip()
test_pin = getpass.getpass("That user's PIN/password (blank to skip cases B, C, E, G): ")

if not test_id:
    sys.exit("An ordinary user's ID is required.")

results = {}

# --- A: baseline. Everything else is judged against this. --------------------
print("\n=== A. Baseline: can the ADMIN see this user's meters? ===")
admin, _ = new_session()
ok, detail = login(admin, admin_id, admin_pw)
print(f"  admin /LOGIN.cmd -> {'OK' if ok else 'FAILED ' + detail}")
baseline = []
if ok:
    users, code, text = fetch_all(admin)
    mine = [u for u in users if u[0] == test_id]
    print(f"  GetUserInformation -> {len(users)} user records")
    if not mine:
        print(f"  !! user {test_id!r} not found -- check the ID; later cases cannot be judged")
    else:
        baseline = mine[0][1]
        print(f"  meters for {test_id}:")
        show_meters(baseline)
        if not any(m[1] or m[2] for m in baseline):
            print("\n  !! No limits or counts. Per-user accounting looks disabled on this")
            print("     device -- there is no quota for an end-user app to display.")
    logout(admin)
results["A admin baseline"] = ("OK" if baseline else "no meters", bool(baseline), False)

# --- B/C/G: the user's own credential ----------------------------------------
user_ok = False
if test_pin:
    print("\n=== B. Can the USER sign in with their PIN as the password? ===")
    co, _ = new_session()
    user_ok, detail = login(co, test_id, test_pin)
    print(f"  /LOGIN.cmd as {test_id} -> {'OK' if user_ok else 'REFUSED'}  {detail}")
    results["B user /LOGIN.cmd"] = ("OK" if user_ok else "refused", False, False)

    if user_ok:
        print("\n=== C. With that session, can they read meters -- and whose? ===")
        seen, code, text = fetch_all(co)
        verdict, got_own, own_only = describe(code, text, test_id, users=seen)
        print(f"  GetUserInformation -> {verdict}")
        if got_own:
            print(f"  meters returned for {test_id}:")
            show_meters([u for u in seen if u[0] == test_id][0][1])
        results["C user session SOAP"] = (verdict, got_own, own_only)

        print("\n=== G. What else does an ordinary session expose? ===")
        for path in ["/home/api/device-status", "/home/api/about", "/home/api/supplies-info",
                     "/home/api/billing-counter", "/home/api/faulthistory",
                     "/jobs/api/job-list?typeFilter=COMPLETED&limit=20",
                     "/addressbook/api/addressbook?lang=en&offset=0&limit=20&fetchCount=1",
                     "/permissions/api/internal-accounting",
                     "/permissions/api/all-users-management"]:
            try:
                r = co.open(urllib.request.Request(f"https://{HOST}{path}",
                                                   headers={"Accept": "application/json"}),
                            timeout=20)
                status, size = r.status, len(r.read())
            except urllib.error.HTTPError as e:
                status, size = e.code, 0
            except Exception:
                status, size = -1, 0
            flag = "  <-- readable by an ordinary user" if status == 200 and size > 0 else ""
            print(f"  {path.split('?')[0]:<46} {status} {size:>7}b{flag}")
        logout(co)
else:
    print("\n=== B, C, G skipped: no PIN given ===")

# --- D: the anonymous endpoint the app never calls ---------------------------
print("\n=== D. Anonymous SOAP endpoint ===")
anon, _ = new_session()
code, text = soap(anon, STANDARD, anonymous=True)
verdict, got_own, own_only = describe(code, text, test_id)
print(f"  /ssm/Management/Anonymous/Aaa/User -> {verdict}")
results["D anonymous endpoint"] = (verdict, got_own, own_only)

# --- E: UsernameToken as the ordinary user -----------------------------------
if test_pin:
    print("\n=== E. UsernameToken as the ordinary user ===")
    for label, value in [("plain", test_pin), ("base64", b64(test_pin))]:
        fresh, _ = new_session()
        code, text = soap(fresh, STANDARD, token=(test_id, value))
        verdict, got_own, own_only = describe(code, text, test_id)
        print(f"  password {label:7} -> {verdict}")
        results[f"E UsernameToken ({label})"] = (verdict, got_own, own_only)

# --- F: ask for one user rather than the whole collection --------------------
# No call site filters today; if the device honours a filter, a client can request
# just itself instead of downloading every record. Tested as admin -- this asks
# whether the SHAPE is supported, independently of who is allowed to send it.
print("\n=== F. Can GetUserInformation be filtered to one user? ===")
admin2, _ = new_session()
ok, _ = login(admin2, admin_id, admin_pw)
if ok:
    shapes = [
        ("Users/User/Authentication/UserID",
         f'<o:Users><o:User><o:Authentication><o:UserType>CO</o:UserType>'
         f'<o:UserID>{test_id}</o:UserID></o:Authentication></o:User></o:Users>' + RESPONDS),
        ("bare UserID element",
         f'<o:UserID>{test_id}</o:UserID>' + TYPES + SCOPE + RESPONDS),
        ("Condition/UserID",
         f'<o:Condition><o:UserID>{test_id}</o:UserID></o:Condition>' + TYPES + SCOPE + RESPONDS),
    ]
    for label, inner in shapes:
        code, text = soap(admin2, inner)
        users = parse_users(text)
        n = len(users) if users else 0
        fault = fault_of(text)
        if fault:
            print(f"  {label:36} -> FAULT {fault[:44]}")
        elif n == 1 and users[0][0] == test_id:
            print(f"  {label:36} -> FILTER HONOURED (1 record, the right one)")
            # Sent as admin, so this says the shape is supported -- not that an
            # ordinary user may send it. It narrows what a relay would fetch.
            results["F single-user filter (as admin)"] = ("honoured", False, False)
        else:
            print(f"  {label:36} -> ignored ({n} records returned)")
    logout(admin2)
else:
    print("  skipped: admin login failed")

# --- verdict -----------------------------------------------------------------
print("\n" + "=" * 74)
routes = {k: v for k, v in results.items() if v[1] and k != "A admin baseline"}
clean = {k: v for k, v in routes.items() if v[2]}
if not baseline:
    print("STOP: no populated meters for this user even as administrator.")
    print("Enable per-user accounting on the device, or there is nothing to display.")
elif clean:
    print("A non-admin route returning ONLY the user's own meters EXISTS:")
    for k, (v, _, _) in clean.items():
        print(f"  - {k}: {v}")
    print("\n=> Direct printer-to-Mac design is viable. Build on one of these.")
elif routes:
    print("The user's meters came back, but so did OTHER USERS' records:")
    for k, (v, _, _) in routes.items():
        print(f"  - {k}: {v}")
    print("\n=> Do NOT build on this. An ordinary user can enumerate the whole")
    print("   directory, which is a disclosure to fix on the device, not a feature.")
    print("   Treat the direct design as unavailable and consider the relay.")
else:
    print("No non-admin route returned the user's own meters.")
    print("\n=> A direct end-user app is not possible against this firmware. The options")
    print("   are a relay service holding the admin credential, or nothing.")
print("=" * 74)
print("\nNo credentials were written to disk.")
