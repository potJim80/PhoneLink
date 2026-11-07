// Audio-thread code for the Phone Link page.
//  player: plays the Mac's sound from a small, self-adjusting buffer (aim: as little delay as
//          the Wi-Fi allows; grows after a dropout, shrinks again once things are steady).
//          Its volume can go far below the phone's own lowest step (gain 0…1, smoothed).
//  mic:    cuts the phone's mic into 10 ms pieces of 16-bit samples for the WebSocket.

class Player extends AudioWorkletProcessor {
	constructor() {
		super();
		this.cap = sampleRate * 2 | 0;
		this.L = new Float32Array(this.cap);
		this.R = new Float32Array(this.cap);
		this.w = 0; this.r = 0;                          // absolute frame counts
		this.srcRate = sampleRate;
		this.pos = 0; this.prevL = 0; this.prevR = 0;    // resampler state across chunks
		this.ms = sampleRate / 1000;
		this.target = 25 * this.ms;
		this.minTarget = 12 * this.ms;
		this.maxTarget = 150 * this.ms;
		this.priming = true;
		this.calm = 0;
		this.underruns = 0;
		this.tick = 0;
		this.gain = 1; this.g = 1;                       // wanted volume, volume now (ramped per block)
		this.port.onmessage = e => {
			const d = e.data;
			if (d.rate) this.srcRate = d.rate;
			if (d.reset) { this.w = this.r = 0; this.pos = 0; this.priming = true; this.target = 25 * this.ms; }
			if ('gain' in d) this.gain = Math.max(0, Math.min(1, +d.gain || 0));
			if (d.pcm) this.push(new Int16Array(d.pcm));
		};
	}

	put(l, r) {
		const i = this.w % this.cap;
		this.L[i] = l; this.R[i] = r; this.w++;
	}

	push(pcm) {                                         // interleaved stereo int16
		const frames = pcm.length >> 1, k = 1 / 32768;
		if (this.srcRate === sampleRate) {
			for (let i = 0; i < frames; i++) this.put(pcm[2 * i] * k, pcm[2 * i + 1] * k);
		} else {
			// Linear interpolation; pos runs from -1 (between the previous chunk's last frame
			// and this chunk's first) up to frames - 1.
			const step = this.srcRate / sampleRate;
			let p = this.pos;
			while (p < frames - 1) {
				const i = Math.floor(p), f = p - i;
				const l0 = i < 0 ? this.prevL : pcm[2 * i] * k, r0 = i < 0 ? this.prevR : pcm[2 * i + 1] * k;
				const l1 = pcm[2 * (i + 1)] * k, r1 = pcm[2 * (i + 1) + 1] * k;
				this.put(l0 + (l1 - l0) * f, r0 + (r1 - r0) * f);
				p += step;
			}
			this.pos = p - frames;
			this.prevL = pcm[2 * (frames - 1)] * k; this.prevR = pcm[2 * (frames - 1) + 1] * k;
		}
		if (this.w - this.r > this.cap) this.r = this.w - this.cap;
	}

	process(_inputs, outputs) {
		const out = outputs[0], oL = out[0], oR = out[1] || out[0], n = oL.length;
		let avail = this.w - this.r;
		if (this.priming) {
			if (avail >= this.target) this.priming = false;
			else { oL.fill(0); oR.fill(0); this.report(avail); return true; }
		}
		// Far behind (Wi-Fi hiccup delivered a burst): jump to the target delay.
		if (avail > this.target + 60 * this.ms) { this.r = this.w - this.target; avail = this.target; }
		// Gentle drift correction: read one frame more or less per block (~0.8%), inaudible.
		let take = n;
		if (avail > this.target + 8 * this.ms) take = n + 1;
		else if (avail < this.target - 8 * this.ms && avail > n) take = n - 1;
		if (avail < take) {                              // ran dry: play what's there, then wait
			for (let i = 0; i < n; i++) {
				if (i < avail) { const j = (this.r + i) % this.cap; oL[i] = this.L[j]; oR[i] = this.R[j]; }
				else { oL[i] = 0; oR[i] = 0; }
			}
			this.r += Math.min(avail, n);
			this.priming = true; this.underruns++; this.calm = 0;
			this.target = Math.min(this.maxTarget, this.target + 10 * this.ms);
		} else {
			const step = take / n;
			for (let i = 0; i < n; i++) {
				const j = (this.r + Math.floor(i * step)) % this.cap;
				oL[i] = this.L[j]; oR[i] = this.R[j];
			}
			this.r += take;
			// Ten steady seconds → try a little less delay.
			if (++this.calm > sampleRate * 10 / n && this.target > this.minTarget) {
				this.target = Math.max(this.minTarget, this.target - 3 * this.ms); this.calm = 0;
			}
		}
		this.volume(oL, oR);
		this.report(this.w - this.r);
		return true;
	}

	volume(oL, oR) {
		const g0 = this.g, n = oL.length, dg = (this.gain - g0) / n;
		if (g0 === 1 && dg === 0) return;
		for (let i = 0; i < n; i++) { const g = g0 + dg * i; oL[i] *= g; if (oR !== oL) oR[i] *= g; }
		this.g = this.gain;
	}

	report(avail) {
		if (++this.tick % 94) return;                     // about 3 times a second
		this.port.postMessage({ bufferMs: avail / this.ms, targetMs: this.target / this.ms, underruns: this.underruns });
	}
}

class Mic extends AudioWorkletProcessor {
	constructor() {
		super();
		this.size = Math.round(sampleRate / 100);
		this.buf = new Int16Array(this.size);
		this.n = 0;
		this.on = true;
		this.port.onmessage = e => { if ('on' in e.data) { this.on = e.data.on; this.n = 0; } };
	}
	process(inputs) {
		const x = inputs[0] && inputs[0][0];
		if (!x || !this.on) return true;
		for (let i = 0; i < x.length; i++) {
			const v = Math.max(-1, Math.min(1, x[i]));
			this.buf[this.n++] = v * 32767;
			if (this.n === this.size) {
				this.port.postMessage(this.buf.buffer, [this.buf.buffer]);
				this.buf = new Int16Array(this.size); this.n = 0;
			}
		}
		return true;
	}
}

registerProcessor('player', Player);
registerProcessor('mic', Mic);
