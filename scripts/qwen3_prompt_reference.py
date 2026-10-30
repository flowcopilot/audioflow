"""Render a reference prompt with Qwen3's original Jinja template.

uv run --with jinja2 scripts/qwen3_prompt_reference.py tokenizer_config.json
Use Qwen/Qwen3-0.6B at revision c1899de289a04d12100db370d81485cdf75e47ca.
"""
import json
import sys
import jinja2

system = 'You are a voice assistant. Reply in one short sentence. Use plain text.'
text = 'What did the speaker say?'
config = json.load(open(sys.argv[1]))
template = jinja2.Environment(trim_blocks=True, lstrip_blocks=True).from_string(config['chat_template'])
prompt = template.render(messages=[{'role': 'system', 'content': system},
    {'role': 'user', 'content': text}], add_generation_prompt=True, enable_thinking=False)
conversations = [
    [{'role': 'user', 'content': 'My name is Ana.'},
     {'role': 'assistant', 'content': 'Hello, Ana. '},
     {'role': 'user', 'content': 'What is my name?'}],
    [{'role': 'user', 'content': 'Say hello.'},
     {'role': 'assistant', 'content': '<think>\nPrivate reasoning.\n</think>\n\nHello!\n'},
     {'role': 'user', 'content': 'Say it again.'}]
]
cases = [{'messages': messages, 'prompt': template.render(
    messages=[{'role': 'system', 'content': system}] + messages,
    add_generation_prompt=True, enable_thinking=False)} for messages in conversations]
print(json.dumps({'revision': 'c1899de289a04d12100db370d81485cdf75e47ca',
    'system': system, 'text': text, 'prompt': prompt, 'conversations': cases}, indent=2))
