import { createFaceController } from '../../frontend/js/ui/faceCanvas.js';
import { ScenarioFrameSequencer } from '../../frontend/js/embodiment/scenarioFrameSequencer.js';
import { getScenarioDefinition, MODEL_SCENARIO_NAMES } from '../../frontend/js/embodiment/scenarioCatalog.js';
import { ESP32Client } from '../../frontend/js/robot/esp32Client.js';
import { CommandQueue } from '../../frontend/js/robot/commandQueue.js';

const pending = new Map(); let sequence = 0;
function request(kind, payload) {
  const id = `face-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('原生指令超时')); }, 10_000);
    pending.set(id, {resolve, reject, timer});
    window.webkit.messageHandlers.face.postMessage({id, kind, payload});
  });
}
class NativeBody extends ESP32Client {
  isConnected() { return this.connected && this.readyState === 1; }
  async writeJsonMessage(payload) { await request('command', payload); }
}
const body = new NativeBody();
const face = createFaceController(document.querySelector('#faceCanvas'));
const queue = new CommandQueue({robotClient: body});
let cameraRunning = false;
const camera = {
  getCameraStatus: () => ({running: cameraRunning, facingMode: 'user'}),
  async captureSnapshot() { const dataUrl = await request('photo', {}); return {ok: true, snapshot: {dataUrl}}; }
};
const sequencer = new ScenarioFrameSequencer({face, commandQueue: queue, cameraInput: camera});
window.looiFace = {
  reply(id, value, error) {
    const call = pending.get(id); if (!call) return;
    pending.delete(id); clearTimeout(call.timer); error ? call.reject(new Error(error)) : call.resolve(value);
  },
  state(value) {
    body.connected = Boolean(value.connected); body.readyState = body.connected ? 1 : 3;
    cameraRunning = Boolean(value.cameraRunning);
    face.setSpeaking(Boolean(value.speaking)); face.setThinking(Boolean(value.thinking));
    if (value.expression) face.setExpression(value.expression);
  },
  async run(name, allowMotion = false) {
    const scenario = getScenarioDefinition(name); if (!scenario) throw new Error('未知动作');
    return sequencer.playFrameSequence({...scenario, frames: scenario.sequence}, {allowMotion, allowCamera: cameraRunning});
  },
  cancel() { sequencer.interrupt('native_stop', 100); queue.cancelMotion('native_stop').catch(() => {}); },
  pause(paused) { document.body.style.visibility = paused ? 'hidden' : 'visible'; }
};
window.webkit.messageHandlers.face.postMessage({kind: 'ready', scenarios: MODEL_SCENARIO_NAMES});
