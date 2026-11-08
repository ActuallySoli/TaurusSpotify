"""Real browser + production HTTP, queue and PCM/WAV relay, with a synthetic Spotify player."""
import json, os, selectors, signal, subprocess, time, urllib.request
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'harness/jam/build'
BUILD.mkdir(exist_ok=True)
(BUILD/'control.json').unlink(missing_ok=True)
logs = (BUILD/'server.log').open('w')
server = subprocess.Popen([str(BUILD/'server')], cwd=ROOT, stdout=subprocess.PIPE, stderr=logs, text=True)
selector = selectors.DefaultSelector(); selector.register(server.stdout, selectors.EVENT_READ)
if not selector.select(10):
    server.terminate(); raise RuntimeError('HTTP fixture did not become ready; check harness/jam/build/server.log')
url = server.stdout.readline().strip()
assert url.startswith('http://'), url
art = '''<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600" viewBox="0 0 600 600"><rect width="600" height="600" fill="#594e7c"/><circle cx="300" cy="270" r="174" fill="#c9abaf"/><path d="M0 370Q150 230 300 360T600 320V600H0" fill="#242b48"/><path d="M0 460Q220 300 600 430V600H0" fill="#171d36"/><text x="42" y="75" fill="#f4dfd3" font-family="sans-serif" font-size="24" letter-spacing="5">THE LISTENING ROOM</text><text x="42" y="554" fill="#f4dfd3" font-family="sans-serif" font-size="37">A little closer</text></svg>'''
metrics = '''(() => {
window.audioTest = {started:0,stopped:0,nonzero:false,maxBuffered:0};
const start = AudioBufferSourceNode.prototype.start, stop = AudioBufferSourceNode.prototype.stop;
AudioBufferSourceNode.prototype.start = function(when,...rest) {
  audioTest.started++; audioTest.maxBuffered=Math.max(audioTest.maxBuffered,when-this.context.currentTime);
  if(this.buffer) audioTest.nonzero ||= this.buffer.getChannelData(0).some(v=>Math.abs(v)>.05);
  return start.call(this,when,...rest);
};
AudioBufferSourceNode.prototype.stop = function(...args) {audioTest.stopped++;return stop.apply(this,args);};
})();'''
def command(value):
    target = BUILD/'control.json'; temporary=BUILD/'control.tmp'
    temporary.write_text(json.dumps(value)); temporary.replace(target)
def wait_js(page, expression, timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if page.evaluate(expression): return
        page.wait_for_timeout(100)
    raise AssertionError(expression + ': ' + page.locator('#audioNote').inner_text())
def add_track(page, value):
    page.locator('#url').fill(value); page.get_by_role('button', name='Request', exact=True).click()
def wait_ready(page):
    expect(page.locator('#connectionText')).to_have_text('In the room')
try:
  with sync_playwright() as p:
    for engine in os.environ.get('WEBJAM_BROWSERS','chromium,webkit').split(','):
      launch = {'headless':True,'timeout':20000}
      if engine=='webkit' and os.environ.get('WEBJAM_WEBKIT_EXECUTABLE'): launch['executable_path']=os.environ['WEBJAM_WEBKIT_EXECUTABLE']
      browser = getattr(p,engine).launch(**launch)
      context = browser.new_context(viewport={'width':1440,'height':1000}, reduced_motion='reduce')
      context.add_init_script(metrics)
      context.route('https://i.scdn.co/**', lambda route: route.fulfill(content_type='image/svg+xml',body=art))
      page=context.new_page(); errors=[]; page.on('pageerror',lambda error:errors.append(str(error)))
      page.goto(url); page.wait_for_load_state('networkidle'); wait_ready(page)
      assert page.evaluate('audioTest.started') == 0, 'no autoplay before the guest chooses listening'
      page.get_by_role('button',name='Start listening').click()
      expect(page.locator('#listenLabel')).to_have_text('Stop listening')
      wait_js(page, 'audioTest.started >= 5 && audioTest.nonzero')
      assert page.evaluate('audioTest.maxBuffered') < 1.5, 'latency stays bounded'
      page.locator('#volume').fill('35'); expect(page.locator('#volumeValue')).to_have_text('35%')
      command({'paused':True}); expect(page.locator('#nowState')).to_have_text('Host is paused')
      page.wait_for_timeout(500); before=page.evaluate('audioTest.started'); page.wait_for_timeout(600)
      assert page.evaluate('audioTest.started') == before, 'paused host cannot schedule stale audio'
      command({'paused':False}); expect(page.locator('#nowState')).to_have_text('Host is playing')
      wait_js(page, 'audioTest.started>'+str(before))
      page.get_by_role('button',name='Stop listening').click(); before=page.evaluate('audioTest.started')
      page.wait_for_timeout(600); assert page.evaluate('audioTest.started') == before, 'Stop cancels pending playback'
      if engine=='chromium':
        page.locator('#name').fill('Alex <img src=x>'); page.locator('#name').blur()
        page.locator('#url').fill('https://open.spotify.com/track/1111111111111111111111')
        page.evaluate("document.querySelector('#add').requestSubmit();document.querySelector('#add').requestSubmit();document.querySelector('#url').value='next draft'")
        expect(page.locator('#msg')).to_contain_text('Requested')
        assert page.locator('#url').input_value() == 'next draft', 'late success preserves newer input'
        assert page.locator('#queue li').count() == 1, 'double submission adds only one request'
        expect(page.locator('#queue')).to_contain_text('Alex <img src=x>')
        assert page.locator('#queue img, #queue script').count() == 0, 'guest content stays literal'
        add_track(page,'https://open.spotify.com/track/1111111111111111111111')
        expect(page.locator('#msg')).to_contain_text('already in the queue')
        assert page.locator('#url').input_value(), 'duplicate errors preserve the pasted link'
        page.locator('#name').fill('Sam');
        add_track(page,'https://open.spotify.com/intl-en/playlist/3333333333333333333333')
        expect(page.locator('#msg')).to_contain_text('Requested')
        expect(page.locator('#queue')).to_contain_text('Playlist')
        page.locator('#tabRequests').click(); expect(page.locator('#requests')).to_contain_text('Queued')
        page.locator('#tabRequests').press('ArrowRight'); expect(page.locator('#tabRecent')).to_be_focused()
        page.locator('#tabQueue').click()
        page.locator('#name').fill('Alex'); page.locator('#url').fill('')
        for width,height,name in [(1440,1000,'desktop'),(390,844,'phone'),(844,390,'landscape'),(320,740,'small')]:
          page.set_viewport_size({'width':width,'height':height}); page.wait_for_timeout(150)
          assert page.evaluate('document.documentElement.scrollWidth<=innerWidth'), 'horizontal overflow at '+name
          page.screenshot(path=str(BUILD/('webjam-'+name+'.png')),full_page=True)
        page.set_viewport_size({'width':390,'height':844})
        command({'position':179.6}); expect(page.locator('#nowTitle')).to_have_text('Your requested song',timeout=6000)
        page.locator('#tabRequests').click(); expect(page.locator('#requests')).to_contain_text('Playing')
        command({'position':179.6}); expect(page.locator('#nowTitle')).to_have_text('First song from the playlist',timeout=6000)
        expect(page.locator('#requests')).to_contain_text('Played')
        page.locator('#tabRecent').click(); expect(page.locator('#recent')).to_contain_text('A little closer')
        # Loss and recovery use actual network requests, not a replacement page script.
        page.route('**/state?**', lambda route:route.abort())
        expect(page.locator('#connectionText')).to_have_text('Reconnecting',timeout=8000)
        page.unroute('**/state?**'); wait_ready(page)
      assert not errors, errors
      print('PASS',engine,'production audio decode/scheduling, pause/resume, stop, page runtime',flush=True)
      context.close(); browser.close()
finally:
  if server.poll() is None:
    server.send_signal(signal.SIGTERM)
    try: server.wait(timeout=8)
    except subprocess.TimeoutExpired: server.kill(); server.wait()
  logs.close()
  report=(BUILD/'server.log').read_text()
  assert 'ERROR: AddressSanitizer' not in report and 'runtime error:' not in report, report
  assert server.returncode == 0, report
print('PASS production HTTP + browser integration; screenshots in harness/jam/build',flush=True)
