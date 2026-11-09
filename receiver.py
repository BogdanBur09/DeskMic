import socket
import threading
import time
import sys
import os
import tkinter as tk
from tkinter import ttk, messagebox
import numpy as np
import sounddevice as sd

UDP_PORT = 50005
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = 'int16'
PACKET_SIZE = 1024


def get_local_ip():
    """Auto-detect the PC's primary LAN IP via dummy UDP connection."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'


def find_target_audio_device():
    """Find VB-Audio Cable / Virtual Audio Cable output device, or fallback to system default."""
    try:
        devices = sd.query_devices()
        keywords = ['cable input', 'virtual audio cable', 'vb-audio', 'line 1 (virtual']
        for kw in keywords:
            for idx, dev in enumerate(devices):
                if dev['max_output_channels'] > 0 and kw in dev['name'].lower():
                    return idx, dev['name']

        default_dev = sd.default.device[1]
        if default_dev is not None and default_dev >= 0:
            return default_dev, devices[default_dev]['name']
        return None, "Default Audio Device"
    except Exception as e:
        return None, f"Error detecting devices: {e}"


class DeskMicReceiverApp:
    def __init__(self, root):
        self.root = root
        self.root.title("DeskMic Receiver")
        self.root.geometry("500x760")
        self.root.minsize(460, 700)
        self.root.configure(bg="#18191c")

        # Network & audio state
        self.local_ip = get_local_ip()
        self.volume_factor = tk.DoubleVar(value=1.0)
        self.is_running = True
        self.is_streaming = False
        self.last_packet_time = 0.0
        self.total_packets = 0
        self.total_bytes = 0
        self.peak_level = 0.0
        self.current_device_idx = None
        self.current_device_name = ""
        self.audio_stream = None
        self.udp_socket = None

        # Manual Latency Reset Flag
        self.flush_requested = False
        self.reset_count = 0
        self.last_reset_msg_time = 0.0

        # DSP Processing Toggles & State
        self.lowcut_enabled = tk.BooleanVar(value=True)
        self.declicker_enabled = tk.BooleanVar(value=True)
        self.gate_enabled = tk.BooleanVar(value=True)
        self.gate_threshold_db = tk.DoubleVar(value=-38.0)
        self.limiter_enabled = tk.BooleanVar(value=True)
        self.agc_enabled = tk.BooleanVar(value=False)

        # DSP filter states
        self.hp_prev_in = 0.0
        self.hp_prev_out = 0.0
        self.gate_current_gain = 1.0
        self.gate_hold_frames = 0
        self.agc_gain = 1.0

        self._setup_style()
        self._build_ui()
        self._init_audio()
        self._start_udp_thread()
        self._start_ui_refresh_loop()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def _setup_style(self):
        style = ttk.Style()
        style.theme_use('clam')
        style.configure(".", background="#18191c", foreground="#f0f0f0")
        style.configure("TLabel", background="#18191c", foreground="#f0f0f0")
        style.configure("Card.TFrame", background="#22242a")
        style.configure("TScale", background="#22242a")
        style.configure("TCheckbutton", background="#22242a", foreground="#ffffff")

    def _build_ui(self):
        # Header banner
        header_frame = tk.Frame(self.root, bg="#18191c")
        header_frame.pack(fill=tk.X, padx=18, pady=(12, 6))

        title_lbl = tk.Label(header_frame, text="🎙️ DeskMic Receiver", font=("Segoe UI", 17, "bold"),
                             bg="#18191c", fg="#ffffff")
        title_lbl.pack(anchor="w")

        sub_lbl = tk.Label(header_frame, text="Low-Latency iOS 9 UDP Audio Stream Receiver",
                           font=("Segoe UI", 9), bg="#18191c", fg="#8e9297")
        sub_lbl.pack(anchor="w")

        # IP Display Card
        ip_card = tk.Frame(self.root, bg="#202225", bd=1, relief="ridge", padx=14, pady=10)
        ip_card.pack(fill=tk.X, padx=18, pady=4)

        ip_guide_lbl = tk.Label(ip_card, text="ENTER THIS IP ON IPHONE:", font=("Segoe UI", 9, "bold"),
                                bg="#202225", fg="#00adb5")
        ip_guide_lbl.pack(anchor="center")

        ip_display_frame = tk.Frame(ip_card, bg="#202225")
        ip_display_frame.pack(anchor="center", pady=(4, 2))

        self.ip_val_lbl = tk.Label(ip_display_frame, text=self.local_ip, font=("Consolas", 22, "bold"),
                                   bg="#202225", fg="#ffffff")
        self.ip_val_lbl.pack(side=tk.LEFT, padx=6)

        copy_btn = tk.Button(ip_display_frame, text="Copy", font=("Segoe UI", 8, "bold"),
                             bg="#2f3136", fg="#ffffff", activebackground="#40444b", activeforeground="#ffffff",
                             relief="flat", padx=6, pady=2, command=self.copy_ip)
        copy_btn.pack(side=tk.LEFT, padx=4)

        port_info = tk.Label(ip_card, text=f"Port: {UDP_PORT} (UDP)  |  16 kHz Mono PCM",
                             font=("Segoe UI", 8), bg="#202225", fg="#8e9297")
        port_info.pack(anchor="center")

        # Connection & VU Status Card
        status_card = tk.Frame(self.root, bg="#22242a", bd=1, relief="ridge", padx=14, pady=10)
        status_card.pack(fill=tk.X, padx=18, pady=4)

        status_header = tk.Frame(status_card, bg="#22242a")
        status_header.pack(fill=tk.X)

        tk.Label(status_header, text="STATUS:", font=("Segoe UI", 9, "bold"),
                 bg="#22242a", fg="#a0a4ab").pack(side=tk.LEFT)

        self.status_indicator = tk.Label(status_header, text="● Waiting for iPhone...",
                                         font=("Segoe UI", 9, "bold"), bg="#22242a", fg="#e0a82e")
        self.status_indicator.pack(side=tk.RIGHT)

        vu_frame = tk.Frame(status_card, bg="#22242a")
        vu_frame.pack(fill=tk.X, pady=(6, 2))

        tk.Label(vu_frame, text="Audio Level:", font=("Segoe UI", 8), bg="#22242a", fg="#b9bbbe").pack(side=tk.LEFT)
        self.vu_canvas = tk.Canvas(vu_frame, height=12, bg="#18191c", highlightthickness=1,
                                   highlightbackground="#36393f")
        self.vu_canvas.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 0))

        metrics_frame = tk.Frame(status_card, bg="#22242a")
        metrics_frame.pack(fill=tk.X, pady=(4, 6))

        self.packets_lbl = tk.Label(metrics_frame, text="Packets: 0", font=("Segoe UI", 8),
                                    bg="#22242a", fg="#8e9297")
        self.packets_lbl.pack(side=tk.LEFT)

        self.bytes_lbl = tk.Label(metrics_frame, text="Data: 0.0 KB", font=("Segoe UI", 8),
                                  bg="#22242a", fg="#8e9297")
        self.bytes_lbl.pack(side=tk.RIGHT)

        # BIG MANUAL RESET LATENCY BUTTON (INSTANT QUEUE PURGE)
        reset_bar = tk.Frame(status_card, bg="#22242a")
        reset_bar.pack(fill=tk.X, pady=(4, 0))

        self.reset_btn = tk.Button(
            reset_bar,
            text="⚡ RESET LATENCY (Flush Queued Packets)",
            font=("Segoe UI", 9, "bold"),
            bg="#2d68c4",
            fg="#ffffff",
            activebackground="#3b7be0",
            activeforeground="#ffffff",
            relief="flat",
            padx=12,
            pady=6,
            command=self.trigger_reset_latency
        )
        self.reset_btn.pack(fill=tk.X)

        self.reset_feedback_lbl = tk.Label(
            status_card,
            text="Click anytime delay builds up to instantly clear backlogged packets.",
            font=("Segoe UI", 8),
            bg="#22242a",
            fg="#8e9297"
        )
        self.reset_feedback_lbl.pack(pady=(4, 0))

        # ONE-CLICK MASTER PRESETS
        preset_frame = tk.Frame(self.root, bg="#18191c")
        preset_frame.pack(fill=tk.X, padx=18, pady=4)

        tk.Label(preset_frame, text="QUICK PRESETS:", font=("Segoe UI", 8, "bold"),
                 bg="#18191c", fg="#a0a4ab").pack(side=tk.LEFT, padx=(0, 8))

        btn_pro = tk.Button(preset_frame, text="🎧 Clean Desk Mic Pro", font=("Segoe UI", 8, "bold"),
                            bg="#2e5c38", fg="#ffffff", activebackground="#387044", activeforeground="#ffffff",
                            relief="flat", padx=8, pady=2, command=self._preset_desk_mic_pro)
        btn_pro.pack(side=tk.LEFT, padx=3)

        btn_vintage = tk.Button(preset_frame, text="🎙️ Vintage Announcer", font=("Segoe UI", 8, "bold"),
                                bg="#423b28", fg="#ffffff", activebackground="#544b33", activeforeground="#ffffff",
                                relief="flat", padx=8, pady=2, command=self._preset_vintage_raw)
        btn_vintage.pack(side=tk.LEFT, padx=3)

        # DSP AUDIO ENHANCEMENTS CARD
        dsp_card = tk.Frame(self.root, bg="#22242a", bd=1, relief="ridge", padx=14, pady=10)
        dsp_card.pack(fill=tk.X, padx=18, pady=4)

        dsp_hdr = tk.Frame(dsp_card, bg="#22242a")
        dsp_hdr.pack(fill=tk.X, pady=(0, 4))

        tk.Label(dsp_hdr, text="DSP ENHANCEMENT CONTROLS (PC SIDE)", font=("Segoe UI", 9, "bold"),
                 bg="#22242a", fg="#00adb5").pack(side=tk.LEFT)

        # 1. 80Hz Low Cut
        lowcut_chk = tk.Checkbutton(dsp_card, text="80Hz Low-Cut (Eliminates desk rumble & thumps)",
                                    variable=self.lowcut_enabled, font=("Segoe UI", 9),
                                    bg="#22242a", fg="#ffffff", selectcolor="#18191c",
                                    activebackground="#22242a", activeforeground="#ffffff")
        lowcut_chk.pack(anchor="w", pady=2)

        # 2. Mouse De-Clicker
        declicker_chk = tk.Checkbutton(dsp_card, text="Mouse De-Clicker (Suppresses sharp microswitch clicks)",
                                       variable=self.declicker_enabled, font=("Segoe UI", 9),
                                       bg="#22242a", fg="#ffffff", selectcolor="#18191c",
                                       activebackground="#22242a", activeforeground="#ffffff")
        declicker_chk.pack(anchor="w", pady=2)

        # 3. Peak Limiter
        limiter_chk = tk.Checkbutton(dsp_card, text="Fast Peak Limiter (Suppresses explosive key clacks)",
                                     variable=self.limiter_enabled, font=("Segoe UI", 9),
                                     bg="#22242a", fg="#ffffff", selectcolor="#18191c",
                                     activebackground="#22242a", activeforeground="#ffffff")
        limiter_chk.pack(anchor="w", pady=2)

        # 4. Smart Noise Gate
        gate_chk = tk.Checkbutton(dsp_card, text="Smart Noise Gate (Silences typing during speech pauses)",
                                  variable=self.gate_enabled, font=("Segoe UI", 9),
                                  bg="#22242a", fg="#ffffff", selectcolor="#18191c",
                                  activebackground="#22242a", activeforeground="#ffffff")
        gate_chk.pack(anchor="w", pady=2)

        # Gate threshold slider row
        gate_thresh_frame = tk.Frame(dsp_card, bg="#22242a")
        gate_thresh_frame.pack(fill=tk.X, padx=(24, 0), pady=(0, 4))

        tk.Label(gate_thresh_frame, text="Gate Sensitivity:", font=("Segoe UI", 8),
                 bg="#22242a", fg="#a0a4ab").pack(side=tk.LEFT)

        self.thresh_lbl = tk.Label(gate_thresh_frame, text=f"{int(self.gate_threshold_db.get())} dB",
                                   font=("Segoe UI", 8, "bold"), bg="#22242a", fg="#00adb5")
        self.thresh_lbl.pack(side=tk.RIGHT)

        thresh_scale = ttk.Scale(gate_thresh_frame, from_=-55.0, to=-20.0,
                                 variable=self.gate_threshold_db, orient=tk.HORIZONTAL,
                                 style="TScale", command=self._on_thresh_change)
        thresh_scale.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=8)

        # 5. Software AGC
        agc_chk = tk.Checkbutton(dsp_card, text="Auto Gain Control / Leveler (Smooth vocal volume)",
                                 variable=self.agc_enabled, font=("Segoe UI", 9),
                                 bg="#22242a", fg="#ffffff", selectcolor="#18191c",
                                 activebackground="#22242a", activeforeground="#ffffff")
        agc_chk.pack(anchor="w", pady=2)

        # Audio Output Device Card
        dev_card = tk.Frame(self.root, bg="#22242a", bd=1, relief="ridge", padx=14, pady=8)
        dev_card.pack(fill=tk.X, padx=18, pady=4)

        tk.Label(dev_card, text="AUDIO OUTPUT ROUTING:", font=("Segoe UI", 8, "bold"),
                 bg="#22242a", fg="#a0a4ab").pack(anchor="w")

        self.device_lbl = tk.Label(dev_card, text="Detecting audio device...", font=("Segoe UI", 8),
                                   bg="#22242a", fg="#43b581", wraplength=440, justify="left")
        self.device_lbl.pack(anchor="w", pady=(2, 4))

        rescan_btn = tk.Button(dev_card, text="🔄 Refresh Device", font=("Segoe UI", 8),
                               bg="#2f3136", fg="#ffffff", activebackground="#40444b", activeforeground="#ffffff",
                               relief="flat", padx=8, pady=2, command=self._reinit_audio)
        rescan_btn.pack(side=tk.LEFT)

        # Volume Slider Card
        vol_card = tk.Frame(self.root, bg="#22242a", bd=1, relief="ridge", padx=14, pady=8)
        vol_card.pack(fill=tk.X, padx=18, pady=4)

        vol_hdr = tk.Frame(vol_card, bg="#22242a")
        vol_hdr.pack(fill=tk.X)

        tk.Label(vol_hdr, text="OUTPUT VOLUME:", font=("Segoe UI", 8, "bold"),
                 bg="#22242a", fg="#a0a4ab").pack(side=tk.LEFT)

        self.vol_pct_lbl = tk.Label(vol_hdr, text="100%", font=("Segoe UI", 8, "bold"),
                                    bg="#22242a", fg="#ffffff")
        self.vol_pct_lbl.pack(side=tk.RIGHT)

        self.vol_scale = ttk.Scale(vol_card, from_=0.0, to=2.0, variable=self.volume_factor,
                                   orient=tk.HORIZONTAL, style="TScale", command=self._on_vol_change)
        self.vol_scale.pack(fill=tk.X, pady=(4, 2))

        vol_presets = tk.Frame(vol_card, bg="#22242a")
        vol_presets.pack(fill=tk.X)
        for val, txt in [(0.0, "Mute"), (0.5, "50%"), (1.0, "100%"), (1.5, "150%"), (2.0, "200%")]:
            b = tk.Button(vol_presets, text=txt, font=("Segoe UI", 7), bg="#2f3136", fg="#b9bbbe",
                          relief="flat", padx=5, pady=1, command=lambda v=val: self._set_vol(v))
            b.pack(side=tk.LEFT, padx=2)

    def trigger_reset_latency(self):
        """Request immediate queue flush and audio buffer reset."""
        self.flush_requested = True
        self.reset_count += 1
        self.last_reset_msg_time = time.time()
        self.reset_feedback_lbl.config(
            text=f"✓ Latency Reset #{self.reset_count}: Socket & Audio Buffers Cleared!",
            fg="#43b581"
        )

    def _preset_desk_mic_pro(self):
        self.lowcut_enabled.set(True)
        self.declicker_enabled.set(True)
        self.limiter_enabled.set(True)
        self.gate_enabled.set(True)
        self.gate_threshold_db.set(-38.0)
        self.agc_enabled.set(False)
        self._on_thresh_change(-38.0)

    def _preset_vintage_raw(self):
        self.lowcut_enabled.set(False)
        self.declicker_enabled.set(False)
        self.limiter_enabled.set(False)
        self.gate_enabled.set(False)
        self.agc_enabled.set(False)

    def _on_thresh_change(self, val):
        db = int(float(val))
        self.thresh_lbl.config(text=f"{db} dB")

    def _on_vol_change(self, val):
        pct = int(float(val) * 100)
        self.vol_pct_lbl.config(text=f"{pct}%")

    def _set_vol(self, val):
        self.volume_factor.set(val)
        self._on_vol_change(val)

    def copy_ip(self):
        self.root.clipboard_clear()
        self.root.clipboard_append(self.local_ip)
        messagebox.showinfo("Copied", f"IP {self.local_ip} copied to clipboard!")

    def _init_audio(self):
        dev_idx, dev_name = find_target_audio_device()
        self.current_device_idx = dev_idx
        self.current_device_name = dev_name

        try:
            if self.audio_stream is not None:
                try:
                    self.audio_stream.stop()
                    self.audio_stream.close()
                except Exception:
                    pass
                self.audio_stream = None

            # Standard smooth blocking stream (rich, full fidelity, zero glitching)
            self.audio_stream = sd.OutputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                device=self.current_device_idx
            )
            self.audio_stream.start()
            self.device_lbl.config(
                text=f"✓ Active: {self.current_device_name} (ID: {self.current_device_idx})",
                fg="#43b581"
            )
        except Exception as e:
            try:
                self.audio_stream = sd.OutputStream(
                    samplerate=SAMPLE_RATE,
                    channels=CHANNELS,
                    dtype=DTYPE
                )
                self.audio_stream.start()
                self.device_lbl.config(
                    text=f"⚠ Device fallback: System Default ({e})",
                    fg="#faa61a"
                )
            except Exception as e2:
                self.device_lbl.config(
                    text=f"✗ Audio Init Failed: {e2}",
                    fg="#f04747"
                )

    def _reinit_audio(self):
        self.local_ip = get_local_ip()
        self.ip_val_lbl.config(text=self.local_ip)
        self._init_audio()

    def _start_udp_thread(self):
        self.udp_thread = threading.Thread(target=self._udp_listener_loop, daemon=True)
        self.udp_thread.start()

    def _process_dsp(self, samples_f32):
        """Real-time DSP rack: Low-cut -> Mouse De-Clicker -> Gate -> Limiter -> AGC."""
        n_samples = len(samples_f32)
        if n_samples == 0:
            return samples_f32

        # 1. 80 Hz Low-Cut (High-Pass Filter for desk rumble)
        if self.lowcut_enabled.get():
            alpha = 0.96954
            out = np.empty_like(samples_f32)
            prev_in = self.hp_prev_in
            prev_out = self.hp_prev_out
            for i in range(n_samples):
                in_s = samples_f32[i]
                out_s = alpha * (prev_out + in_s - prev_in)
                out[i] = out_s
                prev_in = in_s
                prev_out = out_s
            self.hp_prev_in = prev_in
            self.hp_prev_out = prev_out
            samples_f32 = out

        # 2. Mouse De-Clicker (Microswitch impulse suppression)
        if self.declicker_enabled.get() and n_samples > 4:
            diff = np.abs(np.diff(samples_f32, prepend=samples_f32[0]))
            click_thresh = 4200.0  # Slew rate threshold for plastic microswitch snap
            click_indices = np.where(diff > click_thresh)[0]
            if len(click_indices) > 0:
                for idx in click_indices:
                    left = max(0, idx - 1)
                    right = min(n_samples - 1, idx + 1)
                    samples_f32[idx] = (samples_f32[left] * 0.7 + samples_f32[right] * 0.3)

        # 3. Smart Noise Gate
        if self.gate_enabled.get():
            peak = float(np.max(np.abs(samples_f32)))
            peak_db = 20.0 * np.log10((peak + 1e-9) / 32768.0)
            threshold_db = self.gate_threshold_db.get()

            if peak_db >= threshold_db:
                self.gate_hold_frames = 5  # ~160ms hold
            elif self.gate_hold_frames > 0:
                self.gate_hold_frames -= 1

            target_gain = 1.0 if self.gate_hold_frames > 0 else 0.0
            ramp = np.linspace(self.gate_current_gain, target_gain, n_samples)
            samples_f32 = samples_f32 * ramp
            self.gate_current_gain = target_gain

        # 4. Peak Limiter / Soft Clipper
        if self.limiter_enabled.get():
            thresh = 18000.0
            max_val = 32767.0
            abs_s = np.abs(samples_f32)
            over = abs_s > thresh
            if np.any(over):
                excess = abs_s[over] - thresh
                compressed = thresh + (max_val - thresh) * (excess / (excess + 10000.0))
                samples_f32[over] = np.sign(samples_f32[over]) * compressed

        # 5. Software AGC / Auto Leveler
        if self.agc_enabled.get():
            rms = np.sqrt(np.mean(samples_f32 ** 2) + 1e-9)
            if rms > 300.0:
                target_rms = 4000.0
                ideal_gain = np.clip(target_rms / rms, 0.4, 3.0)
                self.agc_gain = self.agc_gain * 0.95 + ideal_gain * 0.05
            samples_f32 = samples_f32 * self.agc_gain

        return samples_f32

    def _udp_listener_loop(self):
        try:
            self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.udp_socket.bind(('', UDP_PORT))
            self.udp_socket.settimeout(0.5)
        except Exception as e:
            print(f"Error binding UDP port {UDP_PORT}: {e}")
            return

        while self.is_running:
            # Handle user's instant latency reset / queue purge
            if self.flush_requested:
                self.flush_requested = False
                try:
                    self.udp_socket.setblocking(False)
                    while True:
                        try:
                            discard = self.udp_socket.recv(4096)
                            if not discard:
                                break
                        except Exception:
                            break
                    self.udp_socket.settimeout(0.5)
                except Exception:
                    pass

                try:
                    if self.audio_stream and self.audio_stream.active:
                        self.audio_stream.stop()
                        self.audio_stream.start()
                except Exception:
                    pass
                continue

            try:
                data, addr = self.udp_socket.recvfrom(2048)
                if not data:
                    continue

                self.last_packet_time = time.time()
                self.total_packets += 1
                self.total_bytes += len(data)

                # Process samples in float32
                raw_samples = np.frombuffer(data, dtype=np.int16).astype(np.float32)

                # Run DSP processing rack
                processed = self._process_dsp(raw_samples)

                # Peak level for VU meter
                if len(processed) > 0:
                    peak = float(np.max(np.abs(processed))) / 32768.0
                    self.peak_level = max(self.peak_level * 0.7, peak)

                # Apply volume slider
                vol = self.volume_factor.get()
                if vol != 1.0:
                    processed = processed * vol

                out_samples = np.clip(processed, -32768, 32767).astype(np.int16)

                # Smooth, reliable direct write (the creamy, unglitched audio)
                if self.audio_stream and self.audio_stream.active:
                    self.audio_stream.write(out_samples)

            except socket.timeout:
                self.peak_level *= 0.5
                continue
            except Exception as e:
                if self.is_running:
                    print(f"Stream error: {e}")
                time.sleep(0.01)

    def _start_ui_refresh_loop(self):
        now = time.time()
        is_active = (now - self.last_packet_time) < 1.2 and (self.total_packets > 0)

        if is_active != self.is_streaming:
            self.is_streaming = is_active
            if is_active:
                self.status_indicator.config(text="● Streaming Active", fg="#43b581")
            else:
                self.status_indicator.config(text="● Waiting for iPhone...", fg="#faa61a")

        self.packets_lbl.config(text=f"Packets: {self.total_packets:,}")
        kb = self.total_bytes / 1024.0
        self.bytes_lbl.config(text=f"Data: {kb:.1f} KB")

        # Reset button feedback text timeout (fade back to default helper note after 3s)
        if self.last_reset_msg_time > 0 and (now - self.last_reset_msg_time > 3.0):
            self.last_reset_msg_time = 0.0
            self.reset_feedback_lbl.config(
                text="Click anytime delay builds up to instantly clear backlogged packets.",
                fg="#8e9297"
            )

        self.vu_canvas.delete("all")
        width = self.vu_canvas.winfo_width()
        height = self.vu_canvas.winfo_height()
        if width > 1:
            meter_w = int(width * min(1.0, self.peak_level * 1.5))
            if meter_w > 0:
                color = "#43b581" if self.peak_level < 0.75 else "#faa61a" if self.peak_level < 0.9 else "#f04747"
                self.vu_canvas.create_rectangle(0, 0, meter_w, height, fill=color, outline="")

        if self.is_running:
            self.root.after(100, self._start_ui_refresh_loop)

    def on_close(self):
        self.is_running = False
        if self.udp_socket:
            try:
                self.udp_socket.close()
            except Exception:
                pass
        if self.audio_stream:
            try:
                self.audio_stream.stop()
                self.audio_stream.close()
            except Exception:
                pass
        self.root.destroy()


def main():
    root = tk.Tk()
    app = DeskMicReceiverApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
