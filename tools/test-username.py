#!/usr/bin/env python3
"""Finds which field persists a user's display name.

Uses ONLY request shapes already proven against this hardware:
  list   = UserTypes + Sort + Scope + Responds   (the shape the web UI itself sends)
  create = AddUserInformation, Authentication{UserType,UserID} only
  delete = Category "Authentication" + User{UserType,UserID}
Each write is followed by a full list re-read and a client-side lookup, because a
success response from this device does not mean the value was stored."""
import ssl, sys, re, getpass, http.cookiejar, urllib.request, urllib.parse, urllib.error

HOST    = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
TEST_ID = sys.argv[2] if len(sys.argv) > 2 else "9999"
FF  = "http://www.fujifilm.com"
CMN = f"{FF}/fb/2021/04/ssm/management/common"
UNS = f"{FF}/fb/2021/04/ssm/management/aaa/user"
UP  = "/fb/2021/04/ssm/management/aaa/user"

ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                     urllib.request.HTTPCookieProcessor(jar))
def b64(s):
    import base64; return base64.b64encode(s.encode()).decode()

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")
data = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(pw)}).encode()
opener.open(urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=data,
    headers={"Content-Type":"application/x-www-form-urlencoded"}), timeout=20).read()
print(f"logged in to {HOST}; test user {TEST_ID}\n")

def call(op, inner):
    action = f"{UP}#{op}"
    env = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
           f'<soap:Header><MessageInformation>'
           f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
           f'<MessageType>Request</MessageType><Action>{action}</Action>'
           f'</MessageInformation></soap:Header>'
           f'<soap:Body><o:{op} xmlns:o="{UNS}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body></soap:Envelope>')
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/Aaa/User", data=env.encode(),
          headers={"Content-Type":"text/xml;charset=UTF-8","SOAPAction":action})
    try:
        r = opener.open(req, timeout=25); return r.status, r.read().decode("utf-8","replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode("utf-8","replace")
    except Exception as e: return -1, str(e)

def faults(t): return re.findall(r'<Value[^>]*>([^<]+)</Value>', t)

def list_users():
    """The proven list query. Returns {userID: {field: value}}."""
    inner = ('<o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>'
             '<o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>'
             '<o:Scope><cmn:Offset>0</cmn:Offset><cmn:Limit>50</cmn:Limit></o:Scope>'
             '<o:Responds>'
             '<cmn:Respond>Authentication/UserID</cmn:Respond>'
             '<cmn:Respond>Authentication/UserName</cmn:Respond>'
             '<cmn:Respond>Authentication/DisplayName</cmn:Respond>'
             '<cmn:Respond>Accounting/UserName</cmn:Respond>'
             '</o:Responds>')
    c, t = call("GetUserInformation", inner)
    if c != 200: return None, f"HTTP {c} {faults(t)}"
    out = {}
    for blk in re.findall(r'<User\b.*?</User>', t, re.S):
        uid = re.search(r'<UserID[^>]*>([^<]*)</UserID>', blk)
        if not uid: continue
        fields = {k: v for k, v in re.findall(r'<(UserName|DisplayName)[^>]*>([^<]*)</\1>', blk)}
        out[uid.group(1).strip()] = fields
    return out, None

def show(tag):
    users, err = list_users()
    if err: return f"{tag}: list failed {err}"
    if TEST_ID not in users: return f"{tag}: user {TEST_ID} NOT PRESENT (total {len(users)})"
    return f"{tag}: {users[TEST_ID] or '(no name fields)'}"

users, err = list_users()
print(f"list query: {'OK, '+str(len(users))+' users' if users is not None else 'FAILED '+str(err)}")
if users is None: sys.exit("cannot proceed without a working read")
print(show("before"))

if TEST_ID not in users:
    c, t = call("AddUserInformation",
        f'<o:Users><o:User><o:Authentication><o:UserType>CO</o:UserType>'
        f'<o:UserID>{TEST_ID}</o:UserID></o:Authentication></o:User></o:Users>')
    print(f"create -> HTTP {c} {faults(t) or 'ok'}")
    print(show("after create"))

U = lambda inner: f'<o:Users><o:User>{inner}</o:User></o:Users>'
AUTH = f'<o:UserType>CO</o:UserType><o:UserID>{TEST_ID}</o:UserID>'
variants = [
 ("Accounting/UserName",      U(f'<o:Authentication>{AUTH}</o:Authentication><o:Accounting>{AUTH}<o:UserName>NAME_ACCT</o:UserName></o:Accounting>')),
 ("Authentication/UserName",  U(f'<o:Authentication>{AUTH}<o:UserName>NAME_AUTH</o:UserName></o:Authentication>')),
 ("Authentication/DisplayName", U(f'<o:Authentication>{AUTH}<o:DisplayName>NAME_DISP</o:DisplayName></o:Authentication>')),
 ("both blocks",              U(f'<o:Authentication>{AUTH}<o:UserName>NAME_BOTH</o:UserName></o:Authentication><o:Accounting>{AUTH}<o:UserName>NAME_BOTH</o:UserName></o:Accounting>')),
]
print()
for label, inner in variants:
    c, t = call("SetUserInformation", inner)
    f = faults(t)
    print(f"  {label:28} write HTTP {c} {'ok' if not f else f}")
    print(f"  {'':28} {show('read')}\n")

print("A NAME_* value surviving the read identifies the field that persists.\n")
if input(f"Delete test user {TEST_ID}? [y/N]: ").strip().lower() == "y":
    c, t = call("DeleteUserInformationAsync",
        f'<o:Category>Authentication</o:Category><o:User><o:UserType>CO</o:UserType>'
        f'<o:UserID>{TEST_ID}</o:UserID></o:User>')
    print(f"delete -> HTTP {c} {faults(t) or 'ok'}")
    print(show("after delete"))
