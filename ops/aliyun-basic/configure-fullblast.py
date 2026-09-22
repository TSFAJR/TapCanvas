#!/usr/bin/env python3
"""Configure owned FullBlast routes through the gateway admin API; no paid calls.
Run after backup/deployment. Never print credentials or channel response bodies.
"""
import http.cookiejar
import json
import pathlib
import urllib.request

env = dict(line.split('=', 1) for line in pathlib.Path('/etc/tap-canvas/runtime.env').read_text().splitlines()
           if '=' in line and not line.startswith('#'))
assert env.get('TAPCANVAS_BASIC_NO_MODELS') == '0', 'Disable no-model clearing policy first'
key = env['FULLBLAST_API_KEY'].strip()
assert key, 'FULLBLAST_API_KEY is required'
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
user_id = ''

def api(path, data=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if user_id:
        headers['New-Api-User'] = user_id
    request = urllib.request.Request('http://127.0.0.1:4455' + path, headers=headers, method=method,
                                     data=json.dumps(data).encode() if data is not None else None)
    with opener.open(request, timeout=45) as response:
        result = json.load(response)
    if result.get('success') is not True:
        raise RuntimeError(f'Gateway operation failed: {method or "GET"} {path}: {result.get("message", "unknown error")}')
    return result.get('data')

user_id = str(api('/api/user/login', {'username': env['NEW_API_ROOT_USERNAME'],
                                    'password': env['NEW_API_ROOT_PASSWORD']})['id'])

def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))

def enum(key, label, values, default):
    return {'key': key, 'label': label, 'type': 'enum', 'default': default,
            'options': [{'value': value, 'label': str(value)} for value in values]}

video_pricing = {'currency': 'CNY', 'billing_mode': 'linear_by_duration_and_resolution',
                 'specs': [{'resolution': '720p', 'cny_per_second': 0.396}]}
image_pricing = {'currency': 'CNY', 'billing_mode': 'fixed_by_spec',
                 'specs': [{'resolution': '1024x1024', 'price_cny': 0.11}]}
models = [
    {'model_name': 'qwen3.7-plus', 'kind': 'chat', 'endpoints': encode(['openai']),
     'description': 'FullBlast：对话、视觉理解与工具调用；普通模式。报价适用输入不超过 256K tokens。',
     'capabilities': encode(['chat', 'vision', 'tool_calling']), 'params_def': '[]', 'pricing_config': ''},
    {'model_name': 'wan2.7-image', 'kind': 'image', 'endpoints': encode(['image-generation']),
     'description': 'FullBlast：文生图，每次一张 1024×1024；本部署未开放图片编辑。',
     'capabilities': encode(['text_to_image']),
     'params_def': encode([enum('image_size', '尺寸', ['1024x1024'], '1024x1024')]),
     'pricing_config': encode(image_pricing)},
    {'model_name': 'wan3.0-video', 'kind': 'video', 'endpoints': encode(['openai-video']),
     'description': 'FullBlast：文字或单张参考图生成视频，720P，默认 5 秒。',
     'capabilities': encode(['text_to_video', 'image_to_video', 'reference_images']),
     'params_def': encode([enum('duration', '时长', [2, 5, 10], 5),
                           enum('size', '比例', ['16:9', '9:16', '1:1'], '16:9'),
                           enum('resolution', '分辨率', ['720p'], '720p'),
                           {'key': 'reference_images', 'type': 'array', 'max': 1}]),
     'pricing_config': encode(video_pricing)},
]
existing = {item['model_name']: item for item in api('/api/models/?p=1&page_size=100')['items']}
ids = {}
for item in models:
    item.update(status=1, sync_official=0, name_rule=0)
    prior = existing.get(item['model_name'])
    if prior:
        item['id'] = prior['id']
        api('/api/models/', item, 'PUT')
        ids[item['model_name']] = prior['id']
    else:
        ids[item['model_name']] = api('/api/models/', item, 'POST')['id']

exchange = float(env['NEW_API_USD_EXCHANGE_RATE'])
api(f'/api/models/{ids["qwen3.7-plus"]}/pricing', {
    'billing_mode': 'per_token', 'selling_multiplier': 1,
    'input_price_usd_per_million': 1.32 / exchange,
    'output_price_usd_per_million': 5.28 / exchange,
    'cache_read_price_usd_per_million': 0.264 / exchange,
    'cache_write_price_usd_per_million': 1.65 / exchange}, 'PUT')
for name, price, specs in [('wan2.7-image', 0.11, image_pricing), ('wan3.0-video', 0.396, video_pricing)]:
    api(f'/api/models/{ids[name]}/pricing', {'billing_mode': 'per_request',
        'selling_multiplier': 1, 'fixed_price': price, 'fixed_price_currency': 'CNY', 'spec_pricing': specs}, 'PUT')

channels = {item['name']: item for item in api('/api/channel/?p=1&page_size=100')['items']}
for name in ids:
    settings = {'default_protocol': {'protocol': 'task.fullblast-video' if name == 'wan3.0-video' else 'openai'}}
    overrides = {}
    if name == 'qwen3.7-plus':
        overrides = {'enable_thinking': False, 'operations': [{'path': 'reasoning_effort', 'mode': 'delete'}]}
    if name == 'wan2.7-image':
        settings.update(image_fixed_model_names={name: True}, image_cost_per_image_cny={name: 0.11}, image_sale_multiplier=1)
        overrides = {'size': '1024x1024', 'n': 1, 'response_format': 'url',
                     'operations': [{'path': field, 'mode': 'delete'} for field in ['metadata', 'resolution', 'image_size']]}
    channel = {'name': 'fullblast-' + name, 'type': 1, 'key': key,
               'models': name, 'base_url': 'https://www.fullblast.cn', 'group': 'default',
               'status': 1, 'priority': 0, 'weight': 1, 'auto_ban': 0,
               'setting': encode(settings), 'param_override': encode(overrides)}
    prior = channels.get(channel['name'])
    if prior:
        channel['id'] = prior['id']
        api('/api/channel/', channel, 'PUT')
    else:
        api('/api/channel/', {'mode': 'single', 'channel': channel}, 'POST')
    print('Configured:', name)

# No blind model resubmission after an ambiguous provider transport failure.
api('/api/option/', {'key': 'RetryTimes', 'value': '0'}, 'PUT')
print('FullBlast configuration complete; no paid requests were submitted.')
