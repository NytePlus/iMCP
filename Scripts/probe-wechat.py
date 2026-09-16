"""Read-only MCP acceptance probe. Prints counts/assertions, never message bodies.
Run only for a conversation explicitly authorized by the owner.
"""
import datetime
import base64
import json
import pathlib
import selectors
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
conversation = sys.argv[1]
p = subprocess.Popen([str(root / 'dist/iMCP.app/Contents/MacOS/imcp-server')],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
selector = selectors.DefaultSelector()
selector.register(p.stdout, selectors.EVENT_READ)
serial = 0

def rpc(method, params):
    global serial
    serial += 1
    p.stdin.write((json.dumps(dict(jsonrpc='2.0', id=serial, method=method, params=params))+'\n').encode())
    p.stdin.flush()
    deadline = time.monotonic()+40
    while time.monotonic() < deadline:
        if not selector.select(max(0, deadline-time.monotonic())):
            raise TimeoutError('MCP response timed out')
        line = p.stdout.readline(4*1024*1024)
        if not line:
            raise RuntimeError('MCP connection closed')
        value = json.loads(line)
        if value.get('id') == serial:
            if 'error' in value:
                raise RuntimeError('MCP protocol error')
            return value['result']
    raise TimeoutError('MCP response timed out')

def tool(name, args):
    result = rpc('tools/call', dict(name='wechat_'+name, arguments=args))
    if result.get('isError'):
        raise RuntimeError('Tool failed: '+name)
    return json.loads(next(x['text'] for x in result['content'] if x['type']=='text'))

def check(name, condition):
    print(name, 'PASS' if condition else 'FAIL', flush=True)
    if not condition:
        raise AssertionError(name)

try:
    rpc('initialize', dict(protocolVersion='2025-03-26', capabilities={},
        clientInfo=dict(name='iMCP Diagnostic Probe', version='1.0')))
    p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    p.stdin.flush()
    status = tool('status', {})
    print('source_available', status.get('source_available'), 'sync_mode', status.get('sync_mode'), 'manual_sync_ready', status.get('manual_sync_ready'), flush=True)
    print('image_key_configured',status.get('image_key_configured'),'image_config_unavailable',status.get('image_config_unavailable'),flush=True)
    print('session_index_diagnostics',status.get('session_index_diagnostics'),flush=True)
    found = tool('find_conversations', dict(query=conversation))['items']
    check('authorized_unique_conversation', len(found)==1 and found[0]['enabled'])
    print('index_state', found[0]['index_state'], flush=True)
    if found[0]['index_state'] != 'ready':
        sys.exit(2)
    base = dict(conversation=conversation, limit=10, order='desc')
    first = tool('get_messages', base)
    items = first['items']
    print('sample_count', len(items), flush=True)
    check('nonempty_history', bool(items))
    next_page = tool('get_messages', dict(base, cursor=first['next_cursor']))
    check('pagination_no_overlap', not ({x['message_id'] for x in items}&{x['message_id'] for x in next_page['items']}))
    m = items[0]
    iso = lambda n: datetime.datetime.fromtimestamp(n, datetime.timezone.utc).isoformat()
    filters = dict(base, start=iso(m['create_time']), end=iso(m['create_time']+1), members=[m['member_id']], types=[m['type']])
    selected = tool('get_messages', filters)['items']
    check('combined_time_member_type', bool(selected) and all(x['member_id']==m['member_id'] and x['type']==m['type'] and x['create_time']==m['create_time'] for x in selected))
    excluded = tool('get_messages', dict(filters, start=iso(m['create_time']-1), end=iso(m['create_time'])))['items']
    check('half_open_time', all(x['create_time'] < m['create_time'] for x in excluded))
    multi = tool('get_messages', dict(base, types=['file','link','image']))['items']
    check('multi_type_filter', all(x['type'] in ['file','link','image'] for x in multi))
    print('multi_type_count', len(multi), flush=True)
    search = tool('search_messages', dict(base, keyword='博士'))
    print('keyword_query_count', len(search['items']), flush=True)
    members = tool('list_members', dict(conversation=conversation))
    print('member_entry_count', len(members['items']), flush=True)
    seen_members={x['member_id'] for x in members['items']}
    member_pages=1
    while members.get('has_more'):
        members=tool('list_members',dict(conversation=conversation,cursor=members['next_cursor']))
        ids={x['member_id'] for x in members['items']}
        check('member_page_no_overlap',not seen_members.intersection(ids))
        seen_members.update(ids);member_pages+=1
        if member_pages>100:raise RuntimeError('member pagination exceeded diagnostic bound')
    print('member_unique_count',len(seen_members),'member_pages',member_pages,flush=True)
    context = tool('get_message_context', dict(message_id=m['message_id'], context=2))
    check('context_contains_anchor', any(x['message_id']==m['message_id'] for x in context['items']))
    updates = dict(conversation=conversation, limit=2)
    check('updates_retry_stable', tool('get_updates', updates)==tool('get_updates', updates))
    media_candidate = None
    for kind in ['file','link','image','voice']:
        typed = tool('get_messages', dict(base, types=[kind], limit=2))['items']
        print('type_sample_'+kind, len(typed), flush=True)
        if typed:
            check('type_filter_'+kind, all(x['type']==kind for x in typed))
        else:
            print('type_filter_'+kind, 'NO_SAMPLE (positive coverage missing)', flush=True)
        if kind=='image' and typed:
            media_candidate = typed[0]['message_id']
    if media_candidate:
        media = rpc('tools/call', dict(name='wechat_get_media', arguments=dict(message_id=media_candidate)))
        print('image_media_is_error', media.get('isError', False), flush=True)
        if media.get('isError'):
            error_text=' '.join(x.get('text','') for x in media.get('content',[]))
            known=['image_reference_missing','image_not_available_locally','media_path_outside_account','media_exceeds_100_MB','Permission denied','No such file','V2 AES key required but not provided','AES decryption failed','invalid dat format']
            print('image_media_error_categories',[x for x in known if x.lower() in error_text.lower()],flush=True)
        print('image_media_content_types', [x.get('type') for x in media.get('content',[])], flush=True)
        if not media.get('isError'):
            links = [x['uri'] for x in media.get('content',[]) if x.get('type')=='resource_link']
            if links:
                resource=rpc('resources/read', dict(uri=links[0]))
                print('image_resource_content_count',len(resource.get('contents',[])),flush=True)
                for content in resource.get('contents',[]):
                    raw=base64.b64decode(content.get('blob',''),validate=True)
                    valid=(raw.startswith(b'\xff\xd8\xff') or raw.startswith(b'\x89PNG\r\n\x1a\n') or raw.startswith((b'GIF87a',b'GIF89a')) or (raw.startswith(b'RIFF') and raw[8:12]==b'WEBP'))
                    print('image_resource_bytes',len(raw),'mime_type',content.get('mimeType'),flush=True)
                    print('image_resource_is_wxgf',raw.startswith(b'wxgf'),flush=True)
                    check('image_resource_signature',valid)
finally:
    p.stdin.close()
    p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
