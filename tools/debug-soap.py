#!/usr/bin/env python3
"""Exercises the Apeos SOAP management service exactly as the app does.
Password is read from the tty; never echoed, stored, or logged."""
import ssl, sys, re, getpass, http.cookiejar, urllib.request, urllib.parse, urllib.error

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
FF   = "http://www.fujifilm.com"
CMN  = f"{FF}/fb/2021/04/ssm/management/common"
UNS, UPATH = f"{FF}/fb/2021/04/ssm/management/aaa/user",    "/fb/2021/04/ssm/management/aaa/user"
ANS, APATH = f"{FF}/fb/2021/04/ssm/management/aaa/account", "/fb/2021/04/ssm/management/aaa/account"

ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                     urllib.request.HTTPCookieProcessor(jar))

def b64(s):
    import base64
    return base64.b64encode(s.encode()).decode()

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")

body = urllib.parse.urlencode({"NAME": b64(user), "PSW": b64(pw)}).encode()
r = opener.open(urllib.request.Request(f"https://{HOST}/LOGIN.cmd", data=body,
      headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=20)
print("LOGIN.cmd ->", r.read().decode()[:80])
print("cookies  ->", [c.name for c in jar] or "(none)", "\n")

def call(seg, ns, path, op, inner):
    action = f"{path}#{op}"
    env = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
           f'<soap:Header><MessageInformation>'
           f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
           f'<MessageType>Request</MessageType><Action>{action}</Action>'
           f'</MessageInformation></soap:Header>'
           f'<soap:Body><o:{op} xmlns:o="{ns}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body>'
           f'</soap:Envelope>')
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/Aaa/{seg}", data=env.encode(),
          headers={"Content-Type": "text/xml;charset=UTF-8", "SOAPAction": action})
    try:
        resp = opener.open(req, timeout=25)
        return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)

def verdict(code, text):
    if code == -1:            return "ERROR " + text[:70]
    if not text.strip():      return f"HTTP {code} EMPTY BODY"
    if "Fault" in text:
        vals = re.findall(r'<[^>]*Value[^>]*>([^<]+)<', text)
        return f"HTTP {code} FAULT {vals[:2]}"
    ids = len(re.findall(r'UserID>', text)) + len(re.findall(r'AccountID>', text))
    return f"HTTP {code} OK ({ids} id elements, {len(text)} bytes)"

scope = '<o:Scope><cmn:Offset>0</cmn:Offset><cmn:Limit>50</cmn:Limit></o:Scope>'
resp  = lambda ps: '<o:Responds>' + ''.join(f'<cmn:Respond>{p}</cmn:Respond>' for p in ps) + '</o:Responds>'

UI_FIELDS = ["Authentication/UserID", "Authentication/UserType",
             "Authentication/Initials", "Authorization/Role/#DESCENDANT"]
types = '<o:UserTypes><o:UserType>KO</o:UserType><o:UserType>CO</o:UserType></o:UserTypes>'

print("=== GetUserInformation ===")
user_shapes = [
    ("app request (ascending)", types + '<o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>' + scope + resp(UI_FIELDS)),
    ("+ Accounting/UserName",   types + '<o:Sort><cmn:Key order="ascending">UserID</cmn:Key></o:Sort>' + scope + resp(UI_FIELDS + ["Accounting/UserName"])),
    ("no sort",                 types + scope + resp(UI_FIELDS)),
    ("CO only",                 '<o:UserTypes><o:UserType>CO</o:UserType></o:UserTypes>' + scope + resp(UI_FIELDS)),
]
best = None
for label, inner in user_shapes:
    c, t = call("User", UNS, UPATH, "GetUserInformation", inner)
    v = verdict(c, t)
    print(f"  {label:26} -> {v}")
    if "OK" in v and "(0 id" not in v and best is None:
        best = (label, t)

print("\n=== GetAccount ===")
AF = ["Accounts/Account/AccountID", "Accounts/Account/Name",
      "Accounts/Account/NewUserDefault", "Accounts/Account/Usage/#CHILD"]
acct_shapes = [
    ("AccountType+Sort+Scope", '<o:AccountType></o:AccountType><o:Sort><cmn:Key order="ascending">Name</cmn:Key></o:Sort>' + scope + resp(AF)),
    ("AccountType+Scope",      '<o:AccountType></o:AccountType>' + scope + resp(AF)),
    ("AccountType only",       '<o:AccountType></o:AccountType>' + resp(AF)),
    ("AccountType=GROUP",      '<o:AccountType>GROUP</o:AccountType>' + scope + resp(AF)),
    ("no AccountType",         scope + resp(AF)),
]
for label, inner in acct_shapes:
    c, t = call("Account", ANS, APATH, "GetAccount", inner)
    print(f"  {label:26} -> {verdict(c, t)}")

if best:
    print(f"\n*** USERS WORKING via: {best[0]} ***")
    print(best[1][:1800])
else:
    print("\n*** No user shape returned records. Last body: ***")
    print(t[:800])
