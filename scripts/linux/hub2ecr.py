"""Copies one tag of the public Docker Hub image to public ECR, registry to registry (only blobs ECR lacks are sent).
The ECR credential is read by the AWS CLI inside this process and is never printed."""
import base64, json, subprocess, sys, urllib.request, urllib.error

SRC_REPO = 'romanvaxman/josi-allinone'
DST_HOST = 'public.ecr.aws'
DST_REPO = 'g3p9e4y8/josi-allinone'
TAG = sys.argv[1]
ACCEPT = ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.oci.image.manifest.v1+json',
                    'application/vnd.docker.distribution.manifest.list.v2+json', 'application/vnd.docker.distribution.manifest.v2+json'])


def req(url, method='GET', headers=None, data=None):
    r = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    return urllib.request.urlopen(r, timeout=300)


def hub_token():
    u = 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:%s:pull' % SRC_REPO
    return json.load(req(u))['token']


def ecr_token():
    out = subprocess.run(['aws', 'ecr-public', 'get-authorization-token', '--region', 'us-east-1', '--query', 'authorizationData.authorizationToken', '--output', 'text'],
                         capture_output=True, text=True, check=True).stdout.strip()
    return out  # base64 of AWS:password; used only as the Bearer value ECR Public accepts


HT = hub_token()
ET = ecr_token()
HUB = 'https://registry-1.docker.io/v2/%s/' % SRC_REPO
ECR = 'https://%s/v2/%s/' % (DST_HOST, DST_REPO)
HH = {'Authorization': 'Bearer ' + HT}
EH = {'Authorization': 'Bearer ' + ET}


def get_manifest(ref):
    resp = req(HUB + 'manifests/' + ref, headers={**HH, 'Accept': ACCEPT})
    return resp.read(), resp.headers.get('Content-Type')


def ecr_has(digest):
    try:
        req(ECR + 'blobs/' + digest, 'HEAD', EH)
        return True
    except urllib.error.HTTPError as e:
        if e.code in (404,):
            return False
        raise


def copy_blob(digest, size):
    if ecr_has(digest):
        print('  have', digest[:19], size)
        return
    print('  send', digest[:19], size)
    data = req(HUB + 'blobs/' + digest, headers=HH).read()
    start = req(ECR + 'blobs/uploads/', 'POST', {**EH, 'Content-Length': '0'})
    loc = start.headers['Location']
    if loc.startswith('/'):
        loc = 'https://%s%s' % (DST_HOST, loc)
    sep = '&' if '?' in loc else '?'
    req(loc + sep + 'digest=' + digest, 'PUT', {**EH, 'Content-Type': 'application/octet-stream', 'Content-Length': str(len(data))}, data)


def put_manifest(ref, body, ctype):
    req(ECR + 'manifests/' + ref, 'PUT', {**EH, 'Content-Type': ctype}, body)


def copy_image(ref, top=False):
    body, ctype = get_manifest(ref)
    m = json.loads(body)
    if 'manifests' in m:
        for sub in m['manifests']:
            copy_image(sub['digest'])
    else:
        copy_blob(m['config']['digest'], m['config']['size'])
        for l in m['layers']:
            copy_blob(l['digest'], l['size'])
    put_manifest(ref, body, ctype)
    print('manifest', ref[:19] if ref.startswith('sha256') else ref, 'ok')


copy_image(TAG, True)
print('done')
