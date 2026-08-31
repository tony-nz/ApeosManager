#!/usr/bin/env python3
"""Verifies the SOAP management service and determines the UsernameToken password
encoding. Password is read from the tty; never echoed, stored, or transmitted
anywhere except the printer itself."""
import ssl, sys, base64, getpass, urllib.request, urllib.error

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.0.2.10"
FF   = "http://www.fujifilm.com"
CMN  = f"{FF}/fb/2021/04/ssm/management/common"
ATK  = f"{FF}/fb/2021/04/ssm/management/authentication/token"
ctx  = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

user = input("Admin user ID [11111]: ").strip() or "11111"
pw   = getpass.getpass("Password: ")

def call(seg, ns, path, op, inner, pwval):
    action = f"{path}#{op}"
    hdr = (f'<atk:Authentication xmlns:atk="{ATK}"><atk:UsernameToken>'
           f'<atk:Username>{user}</atk:Username><atk:Password>{pwval}</atk:Password>'
           f'</atk:UsernameToken></atk:Authentication>') if pwval is not None else ''
    body = (f'<?xml version="1.0" encoding="UTF-8"?>'
            f'<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
            f'<soap:Header>{hdr}<MessageInformation>'
            f'<MessageExchangeType>RequestResponse</MessageExchangeType>'
            f'<MessageType>Request</MessageType><Action>{action}</Action>'
            f'</MessageInformation></soap:Header>'
            f'<soap:Body><o:{op} xmlns:o="{ns}" xmlns:cmn="{CMN}">{inner}</o:{op}></soap:Body>'
            f'</soap:Envelope>')
    req = urllib.request.Request(f"https://{HOST}/ssm/Management/Aaa/{seg}", data=body.encode(),
          headers={"Content-Type": "text/xml;charset=UTF-8", "SOAPAction": action})
    try:
        r = urllib.request.urlopen(req, context=ctx, timeout=20)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, str(e)

ACCT = f"{FF}/fb/2021/04/ssm/management/aaa/account"
APATH = "/fb/2021/04/ssm/management/aaa/account"
scope = '<o:Scope><cmn:Offset>0</cmn:Offset><cmn:Limit>50</cmn:Limit></o:Scope>'
resp  = '<o:Responds>' + ''.join(f'<cmn:Respond>{p}</cmn:Respond>' for p in
        ["Accounts/Account/AccountID","Accounts/Account/Name",
         "Accounts/Account/NewUserDefault","Accounts/Account/Usage/#CHILD"]) + '</o:Responds>'

print(f"\nTesting GetAccount against {HOST} …\n")
working = None
for label, val in [("plain", pw), ("base64", base64.b64encode(pw.encode()).decode())]:
    code, text = call("Account", ACCT, APATH, "GetAccount", scope + resp, val)
    ok = code == 200 and "Fault" not in text
    print(f"  password as {label:7} -> HTTP {code}  {'OK' if ok else 'refused'}")
    if ok and working is None:
        working = label
        print("\n--- GetAccount response ---")
        print(text[:2000])

print(f"\nResult: UsernameToken password encoding = {working or 'NEITHER WORKED'}")
if working is None:
    print("Last response:\n", text[:900])
