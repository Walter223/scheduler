"""Read only the current run's verification email; never expose its action token."""
import html, json, os, re, sys, threading, time, urllib.parse, urllib.request
from pathlib import Path
import auth
path=Path(os.environ['BFF_E2E_FIXTURE'])
fixture=json.loads(path.read_text());run=fixture['run_id']
identity=next(u for u in fixture['users'] if u['kind']=='registration')
auth.require(re.fullmatch(r'magnum-bff-e2e-[0-9a-f]{32}',run) and identity['username']==run+'-registration@example.invalid','Unexpected registration fixture')
realm,=auth.admin_get('realms/'+run)
auth.require(realm.get('attributes',{}).get('magnum.e2e.owner')==run,'Unowned test realm')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def get(route):
    with opener.open('http://127.0.0.1:8025/api/v1/'+route,timeout=5) as response:
        return json.load(response)
def messages():
    data=get('search?'+urllib.parse.urlencode({'query':'to:'+identity['email'],'limit':50}))
    return data.get('messages',[])
if '--cleanup' in sys.argv:
    ids=[]
    for summary in messages():
        message=get('message/'+summary['ID'])
        auth.require(message.get('To') and all(x['Address']==identity['email'] for x in message['To']),'Mail ownership mismatch')
        ids.append(summary['ID'])
    if ids:
        request=urllib.request.Request('http://127.0.0.1:8025/api/v1/messages',data=json.dumps({'IDs':list(set(ids))}).encode(),headers={'Content-Type':'application/json'},method='DELETE')
        with opener.open(request,timeout=5): pass
    auth.require(not messages(),'Owned verification email cleanup incomplete')
    print('PASS: owned registration emails cleaned')
else:
    users,=auth.admin_get('realms/'+run+'/users?username='+identity['username']+'&exact=true')
    auth.require(len(users)==1 and users[0]['username']==identity['username'],'Registration identity missing')
    identity['subject']=users[0]['id']
    deadline=time.monotonic()+10
    found=messages()
    while not found and time.monotonic()<deadline:
        threading.Event().wait(.1) # SMTP delivery readiness, not browser timing.
        found=messages()
    auth.require(bool(found),'Owned verification email not delivered')
    message=get('message/'+found[0]['ID'])
    auth.require(all(x['Address']==identity['email'] for x in message['To']),'Mail ownership mismatch')
    text=html.unescape(message.get('Text','') or message.get('HTML',''))
    links=re.findall(r'http://auth\.magnum\.test:8080/realms/'+re.escape(run)+r'/login-actions/action-token\?[^\s<>"\']+',text)
    auth.require(bool(links),'Owned verification link unavailable')
    fixture['registration_verification_url']=links[0]
    path.write_text(json.dumps(fixture));path.chmod(0o600)
    print('PASS: owned email link stored privately for browser verification')
