#!/usr/bin/env python3
"""Determines how a contact is created, updated and deleted.

WRITES TO THE DEVICE: creates a test contact, edits it, then deletes it. Every step is
verified by reading the list back, because this device returns success for writes it
does not apply. Confirms before starting. Password read from the tty."""
import ssl, sys, json, getpass, http.cookiejar, urllib.request, urllib.parse, urllib.error

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
MARK = "ZZ-ApeosManager-Test"
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE

def b64(s):
    import base64; return base64.b64encode(s.encode()).decode()

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")
print(f"\nThis CREATES, EDITS and DELETES a contact named '{MARK}' on {HOST}.")
if input("Continue? [y/N]: ").strip().lower() != "y":
    sys.exit("aborted")

jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                 urllib.request.HTTPCookieProcessor(jar))
data = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(pw)}).encode()
op.open(urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=15).read()
print("logged in\n")

def call(method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"https://{HOST}{path}", data=body, method=method,
          headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        r = op.open(req, timeout=25); return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)

AB = "/addressbook/api/addressbook"

def find(name):
    """Reads the whole book and returns the contact with this DisplayName."""
    offset, total = 0, None
    while True:
        c, b = call("GET", f"{AB}?lang=en&offset={offset}&limit=20&fetchCount=1")
        if c != 200: return None
        j = json.loads(b)
        cc = j.get("ContactCount")
        if total is None:
            total = cc.get("ContactCount") if isinstance(cc, dict) else (cc or 0)
        batch = j.get("ContactList") or []
        for x in batch:
            if x.get("DisplayName") == name: return x
        offset += 20
        if not batch or offset >= (total or 0): return None

print("=== create ===")
# Shape mirrors what a read returns, which is the only shape known to be correct here.
candidates = [
  ("full person + email", {
     "ContactType": "PERSON", "DisplayName": MARK, "LastName": "Test", "FirstName": "Apeos",
     "CompanyName": "", "Key": MARK.lower(), "Favorite": False,
     "DestList": [{"DestType": "EMAIL", "Email": {"MailAddress": "apeos-test@example.invalid"}}]}),
  ("minimal person + email", {
     "ContactType": "PERSON", "DisplayName": MARK,
     "DestList": [{"DestType": "EMAIL", "Email": {"MailAddress": "apeos-test@example.invalid"}}]}),
  ("wrapped in Contact", {
     "Contact": {"ContactType": "PERSON", "DisplayName": MARK,
       "DestList": [{"DestType": "EMAIL", "Email": {"MailAddress": "apeos-test@example.invalid"}}]}}),
]
created = None
for label, payload in candidates:
    code, body = call("POST", "/addressbook/api/contact", payload)
    hit = find(MARK)
    print(f"  {label:24} HTTP {code:4} {body[:70].strip()!r} -> {'CREATED' if hit else 'not present'}")
    if hit:
        created = hit
        print(f"    ContactId={hit.get('ContactId')}")
        break

if not created:
    print("\n*** No create payload worked. Nothing to clean up. ***")
    sys.exit(0)

cid = created.get("ContactId")

print("\n=== update (rename) ===")
upd = dict(created); upd["DisplayName"] = MARK + "-2"
code, body = call("PUT", "/addressbook/api/contact", upd)
after = find(MARK + "-2")
print(f"  PUT contact              HTTP {code:4} -> {'RENAMED' if after else 'unchanged'}")
target = after or created
name_now = MARK + "-2" if after else MARK

print("\n=== delete ===")
for label, method, path, payload in [
    ("DELETE ?contactId", "DELETE", f"/addressbook/api/contact?contactId={cid}", None),
    ("POST addressbook",  "POST",   "/addressbook/api/addressbook", {"ContactIdList": [cid]}),
]:
    code, body = call(method, path, payload)
    gone = find(name_now) is None
    print(f"  {label:22} HTTP {code:4} -> {'DELETED' if gone else 'still present'}")
    if gone: break
else:
    print(f"\n  !! Test contact '{name_now}' (ContactId {cid}) could NOT be deleted.")
    print("     Remove it from the printer's web UI: Address Book -> select -> Delete.")
