#!/usr/bin/env python3
"""Reads one user's permission and e-mail fields, and reports which of them this model
actually implements -- the questions behind the app's Permissions editor.

Three things it establishes:

  * whether `UserIDs/UserID` narrows GetUserInformation to a single record (the device's
    own account page sends it, and it is the only filter shape the device accepts);
  * which of the permission Responds paths this model answers, since a path naming an
    element the model lacks faults the whole request rather than omitting one value;
  * what the fields read back as, so the enum values in AccountModels.swift can be
    checked against hardware.

Read-only: every request is a GET or a Get* SOAP operation. Nothing is created,
modified or deleted. The password is read from the tty; never echoed, stored, logged
or sent anywhere except the printer itself.

Usage: probe-user-permissions.py <printer-host> [user-id]
"""
import base64, getpass, http.cookiejar, re, ssl, sys
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

if len(sys.argv) < 2:
    sys.exit(__doc__.strip().splitlines()[-1])
HOST = sys.argv[1]
WANT = sys.argv[2] if len(sys.argv) > 2 else None

FF    = "http://www.fujifilm.com"
CMN   = f"{FF}/fb/2021/04/ssm/management/common"
UNS   = f"{FF}/fb/2021/04/ssm/management/aaa/user"
UPATH = "/fb/2021/04/ssm/management/aaa/user"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

b64 = lambda s: base64.b64encode(s.encode()).decode()


# --- transport ---------------------------------------------------------------

def new_session():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                       urllib.request.HTTPCookieProcessor(jar))


def login(opener, user, password):
    """/LOGIN.cmd takes NAME and PSW each Base64-encoded, and answers {"result":"0"}."""
    body = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(password)}).encode()
    req = urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        text = opener.open(req, timeout=20).read().decode("utf-8", "replace")
    except Exception as e:
        return False, f"ERROR {e}"
    return re.search(r'"result"\s*:\s*"?0"?', text) is not None, text.strip()[:120]


def logout(opener):
    """Frees the device-side session; these printers allow only a few at once."""
    try:
        opener.open(urllib.request.Request(f"https://{HOST}/LOGOUT.cmd", data=b""), timeout=10)
    except Exception:
        pass


def soap(opener, inner, op="GetUserInformation"):
    action = f"{UPATH}#{op}"
    env = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
           f'<soap:Header><MessageInformation>'
           f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
           f'<MessageType>Request</MessageType><Action>{action}</Action>'
           f'</MessageInformation></soap:Header>'
           f'<soap:Body><o:{op} xmlns:o="{UNS}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body>'
           f'</soap:Envelope>')
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/Aaa/User", data=env.encode(),
                                 headers={"Content-Type": "text/xml;charset=UTF-8",
                                          "SOAPAction": action})
    try:
        r = opener.open(req, timeout=25)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)


def get_json(opener, path):
    req = urllib.request.Request(f"https://{HOST}{path}", headers={"Accept": "application/json"})
    try:
        r = opener.open(req, timeout=20)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)


# --- request fragments -------------------------------------------------------

TYPES = '<o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>'
SORT  = '<o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>'
scope = lambda off, lim=50: f'<o:Scope><cmn:Offset>{off}</cmn:Offset><cmn:Limit>{lim}</cmn:Limit></o:Scope>'
responds = lambda paths: '<o:Responds>' + ''.join(
    f'<cmn:Respond>{p}</cmn:Respond>' for p in paths) + '</o:Responds>'

# Element order matters: the operation is a schema sequence and UserIDs leads it.
ids = lambda uid: f'<o:UserIDs><o:UserID>{uid}</o:UserID></o:UserIDs>'

IDENTITY = ["Authentication/UserID", "Authentication/UserType"]
FULL = IDENTITY + [
    "Authentication/ProhibitLoginWith/ManualEntry",
    "Authentication/ProhibitLoginWith/CardEntry",
    "Authentication/MailAddress",
    "Authorization/TraditionalRole",
    "Authorization/PermissionGroup/Index",
    "Authorization/PermissionGroup/Name",
    "Authorization/ColorModePermission/Copy",
    "Authorization/ColorModePermission/Fax",
    "Authorization/ColorModePermission/Scan",
    "Authorization/ColorModePermission/Print",
]
LEAN = [p for p in FULL
        if not p.endswith("CardEntry") and not p.endswith("ColorModePermission/Fax")]
MAIL_ONLY = IDENTITY + ["Authentication/MailAddress"]


# --- parsing -----------------------------------------------------------------

def local(el):
    return el.tag.rsplit('}', 1)[-1]


def fault_of(text):
    if "Fault" not in text:
        return None
    vals = re.findall(r'<[^>]*Value[^>]*>([^<]+)<', text)
    strs = re.findall(r'<[^>]*faultstring[^>]*>([^<]+)<', text)
    return " / ".join(filter(None, [vals[0] if vals else None,
                                    strs[0] if strs else None])) or "fault"


def users_in(text):
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return []
    return [el for el in root.iter() if local(el) == "User"]


def first_text(el, name):
    for d in el.iter():
        if local(d) == name:
            return (d.text or "").strip()
    return None


def user_id_of(el):
    return first_text(el, "UserID")


def child_text(el, name):
    for d in el:
        if local(d) == name:
            return (d.text or "").strip()
    return None


def find(el, name):
    for d in el.iter():
        if local(d) == name:
            return d
    return None


def describe(el):
    """The fields the app reads, laid out as the device reports them."""
    out = []
    mail = find(el, "MailAddress")
    out.append(("Authentication/MailAddress",
                "(absent)" if mail is None else repr((mail.text or "").strip())))

    login = find(el, "ProhibitLoginWith")
    if login is None:
        out.append(("Authentication/ProhibitLoginWith", "(absent)"))
    else:
        for name in ("ManualEntry", "CardEntry"):
            v = child_text(login, name)
            out.append((f"  ProhibitLoginWith/{name}", "(absent)" if v is None else repr(v)))

    for name in ("TraditionalRole",):
        el2 = find(el, name)
        out.append((f"Authorization/{name}",
                    "(absent)" if el2 is None else repr((el2.text or "").strip())))

    group = find(el, "PermissionGroup")
    if group is None:
        out.append(("Authorization/PermissionGroup", "(absent)"))
    else:
        for name in ("Index", "Name"):
            v = child_text(group, name)
            out.append((f"  PermissionGroup/{name}", "(absent)" if v is None else repr(v)))

    modes = find(el, "ColorModePermission")
    if modes is None:
        out.append(("Authorization/ColorModePermission", "(absent)"))
    else:
        for name in ("Copy", "Fax", "Scan", "Print"):
            v = child_text(modes, name)
            out.append((f"  ColorModePermission/{name}", "(absent)" if v is None else repr(v)))
    return out


# --- the probe ---------------------------------------------------------------

def attempt(opener, label, inner, uid):
    code, text = soap(opener, inner)
    fault = fault_of(text)
    if fault:
        print(f"  {label:34} HTTP {code}  FAULT {fault[:60]}")
        return None
    if code == -1:
        print(f"  {label:34} ERROR {text[:60]}")
        return None
    found = [el for el in users_in(text) if user_id_of(el) == uid]
    others = len(users_in(text)) - len(found)
    note = f"{len(found)} match" + (f", {others} other records" if others else "")
    print(f"  {label:34} HTTP {code}  {note}")
    return found[0] if found else None


def main():
    admin = input("Admin user ID [11111]: ").strip() or "11111"
    password = getpass.getpass("Password: ")

    opener = new_session()
    ok, detail = login(opener, admin, password)
    print(f"\n/LOGIN.cmd as {admin}: {'OK' if ok else 'FAILED ' + detail}")
    if not ok:
        return 1

    try:
        uid = WANT
        if not uid:
            code, text = soap(opener, TYPES + SORT + scope(0, 20) + responds(IDENTITY))
            candidates = [user_id_of(el) for el in users_in(text)]
            candidates = [c for c in candidates if c]
            if not candidates:
                print("No users on this device to probe.")
                return 1
            print("\nUsers on this device (first page):", ", ".join(candidates))
            uid = input(f"User to read [{candidates[0]}]: ").strip() or candidates[0]

        print(f"\n1. Does UserIDs/UserID narrow the result to one record?")
        one = attempt(opener, "UserIDs + full permissions", ids(uid) + responds(FULL), uid)
        if one is None:
            attempt(opener, "UserIDs + identity only", ids(uid) + responds(IDENTITY), uid)

        print(f"\n2. Which Responds tiers does this model answer?")
        record = one
        for label, paths in (("full", FULL), ("lean (no fax, no card)", LEAN),
                             ("mail address only", MAIL_ONLY)):
            el = attempt(opener, f"unfiltered walk, {label}",
                         TYPES + SORT + scope(0, 50) + responds(paths), uid)
            if record is None and el is not None:
                record = el

        if record is None:
            print(f"\nNo record for '{uid}' came back; nothing to report.")
            return 1

        print(f"\n3. Fields as the device reports them for '{uid}':")
        for name, value in describe(record):
            print(f"  {name:44} {value}")

        print("\n4. Permission groups (/permissions/api/authorization-groups):")
        code, text = get_json(opener, "/permissions/api/authorization-groups")
        print(f"  HTTP {code}")
        print("  " + text.strip()[:1200].replace("\n", "\n  "))
    finally:
        logout(opener)
    return 0


if __name__ == "__main__":
    sys.exit(main())
