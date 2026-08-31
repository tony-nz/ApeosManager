#!/usr/bin/env python3
"""Determines how this device creates a user.

First dumps one EXISTING user's complete record (every field the device stores),
then tries candidate create requests until one is accepted, then deletes whatever
it created. Writes to the device: it creates and removes a single test user.
Password is read from the tty."""
import ssl, sys, re, getpass, http.cookiejar, urllib.request, urllib.parse, urllib.error

HOST    = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
TEST_ID = sys.argv[2] if len(sys.argv) > 2 else "99999"
FF   = "http://www.fujifilm.com"
CMN  = f"{FF}/fb/2021/04/ssm/management/common"
UNS  = f"{FF}/fb/2021/04/ssm/management/aaa/user"
UP   = "/fb/2021/04/ssm/management/aaa/user"

ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                     urllib.request.HTTPCookieProcessor(jar))

def b64(s):
    import base64; return base64.b64encode(s.encode()).decode()

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")
print(f"\nThis will CREATE and then DELETE user '{TEST_ID}' on {HOST}.")
if input("Continue? [y/N]: ").strip().lower() != "y":
    sys.exit("aborted")

data = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(pw)}).encode()
r = opener.open(urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=data,
      headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=20)
print("login:", r.read().decode()[:60], "\n")

def call(op, inner):
    action = f"{UP}#{op}"
    env = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
           f'<soap:Header><MessageInformation>'
           f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
           f'<MessageType>Request</MessageType><Action>{action}</Action>'
           f'</MessageInformation></soap:Header>'
           f'<soap:Body><o:{op} xmlns:o="{UNS}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body>'
           f'</soap:Envelope>')
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/Aaa/User", data=env.encode(),
          headers={"Content-Type": "text/xml;charset=UTF-8", "SOAPAction": action})
    try:
        resp = opener.open(req, timeout=25); return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode("utf-8", "replace")
    except Exception as e: return -1, str(e)

def fault(text):
    m = re.findall(r'<Value[^>]*>([^<]+)</Value>', text)
    return m[0] if m else None

# ---- 1. full record of an existing user -------------------------------------
print("=== complete record of one existing user ===")
resp = ('<o:Responds>'
        '<cmn:Respond>Authentication/#DESCENDANT</cmn:Respond>'
        '<cmn:Respond>Authorization/#DESCENDANT</cmn:Respond>'
        '<cmn:Respond>Accounting/#DESCENDANT</cmn:Respond>'
        '</o:Responds>')
c, t = call("GetUserInformation",
            '<o:UserTypes><o:UserType>CO</o:UserType></o:UserTypes>'
            '<o:Scope><cmn:Offset>0</cmn:Offset><cmn:Limit>1</cmn:Limit></o:Scope>' + resp)
if c == 200 and "<User" in t:
    body = re.search(r'<Users>(.*?)</Users>', t, re.S)
    print(body.group(1)[:2200] if body else t[:1500])
else:
    print(f"HTTP {c} fault={fault(t)}")
print()

# ---- 2. candidate create requests -------------------------------------------
A = lambda inner: f'<o:Users><o:User>{inner}</o:User></o:Users>'
ROLE = ('<o:Authorization><o:Role><o:RoleID>'
        '<o:Category>DeviceUsage</o:Category><o:Name>Basic User</o:Name>'
        '</o:RoleID><o:RoleType>Basic</o:RoleType></o:Role></o:Authorization>')

variants = [
 ("Add: Auth{Type,ID}",              "AddUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID></o:Authentication>')),
 ("Add: Auth{Type,ID,Name}",         "AddUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName></o:Authentication>')),
 ("Add: Auth{Type,ID,Name,Pwd}",     "AddUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName><o:Password>Test12345</o:Password></o:Authentication>')),
 ("Add: Auth + Authorization",       "AddUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName></o:Authentication>{ROLE}')),
 ("Add: Auth + Authz + Accounting",  "AddUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName></o:Authentication>{ROLE}<o:Accounting><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName></o:Accounting>')),
 ("Set: Auth{Type,ID,Name}",         "SetUserInformation", A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID><o:UserName>Test User</o:UserName></o:Authentication>')),
]

winner = None
for label, op, inner in variants:
    c, t = call(op, inner)
    f = fault(t)
    ok = (c == 200 and f is None)
    print(f"  {label:34} -> HTTP {c} {'OK' if ok else 'fault ' + str(f)}")
    if ok and winner is None:
        winner = (label, op, inner)
        break

print()
if winner:
    print(f"*** CREATE WORKS VIA: {winner[0]}  (operation {winner[1]}) ***")
    print("request body:\n" + winner[2])
    c, t = call("DeleteUserInformationAsync",
                A(f'<o:Authentication><o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID></o:Authentication>'))
    print(f"\ncleanup delete -> HTTP {c} fault={fault(t)}")
    print("Verify in the web UI that test user", TEST_ID, "is gone.")
else:
    print("*** No variant created a user. Nothing to clean up. ***")
