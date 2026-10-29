package com.airscreen.tv

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Plays the Mac's system audio.
 *
 * Frames arrive on a WebRTC network thread and are handed to one worker, which
 * is the only thread that ever touches the `AudioTrack` or the decoder. That
 * removes the lock the previous PCM-only path needed, and with it the window
 * where a frame could land on a track that was being released.
 *
 * Both wire codecs are accepted whatever was negotiated, because the frame tag
 * is authoritative — see [AudioWire].
 */
class AudioOutput {
    companion object {
        private const val SAMPLE_RATE = 48_000
        private const val CHANNELS = 2
        /** 20 ms frames; two seconds of slack before we start dropping. */
        private const val QUEUE_CAPACITY = 100
        private const val FRAME_DURATION_US = 20_000L
        /**
         * libopus' lookahead at 48 kHz. Only trims the first few milliseconds of
         * the stream, so an approximation here is inaudible on a live feed.
         */
        private const val PRE_SKIP_SAMPLES = 312
        private const val PRE_SKIP_NS = PRE_SKIP_SAMPLES * 1_000_000_000L / SAMPLE_RATE
        private const val SEEK_PRE_ROLL_NS = 80_000_000L
    }

    private val queue = ArrayBlockingQueue<ByteArray>(QUEUE_CAPACITY)
    private var worker: Thread? = null
    private var track: AudioTrack? = null
    private var decoder: MediaCodec? = null
    private var presentationTimeUs = 0L

    @Volatile private var running = false
    @Volatile var droppedFrames = 0L
        private set
    @Volatile var playedFrames = 0L
        private set
    /** Set once a frame of each kind has actually been played. */
    @Volatile var activeCodec: String? = null
        private set

    fun start() {
        if (running) return
        running = true
        queue.clear()
        val thread = Thread({ run() }, "airscreen-audio")
        thread.isDaemon = true
        worker = thread
        thread.start()
    }

    /** Called from the data channel thread. Never blocks. */
    fun submit(frame: ByteArray) {
        if (!running || frame.isEmpty()) return
        if (!queue.offer(frame)) {
            // Behind: shed the oldest so latency does not grow without bound.
            queue.poll()
            droppedFrames++
            queue.offer(frame)
        }
    }

    fun close() {
        running = false
        worker?.interrupt()
        worker = null
        queue.clear()
    }

    private fun run() {
        try {
            openTrack()
            while (running) {
                val frame = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                when (frame[0]) {
                    AudioWire.TAG_PCM16 -> playPcm(frame, 1, frame.size - 1)
                    AudioWire.TAG_OPUS -> playOpus(frame, 1, frame.size - 1)
                    else -> println("AUDIO: unknown frame tag ${frame[0]}")
                }
            }
        } catch (_: InterruptedException) {
            // close()
        } catch (e: Exception) {
            println("AUDIO: worker stopped: $e")
        } finally {
            releaseDecoder()
            releaseTrack()
        }
    }

    private fun openTrack() {
        val minBuffer = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT
        )
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuffer * 4, 16_384))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .apply { play() }
    }

    private fun playPcm(data: ByteArray, offset: Int, length: Int) {
        if (length <= 0) return
        track?.write(data, offset, length)
        playedFrames++
        activeCodec = "pcm16"
    }

    private fun playOpus(packet: ByteArray, offset: Int, length: Int) {
        if (length <= 0) return
        val codec = decoder ?: openDecoder() ?: return
        val inputIndex = codec.dequeueInputBuffer(20_000)
        if (inputIndex >= 0) {
            codec.getInputBuffer(inputIndex)?.apply {
                clear()
                put(packet, offset, length)
            }
            codec.queueInputBuffer(inputIndex, 0, length, presentationTimeUs, 0)
            presentationTimeUs += FRAME_DURATION_US
        } else {
            droppedFrames++
        }
        drainDecoder(codec)
    }

    private fun drainDecoder(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var index = codec.dequeueOutputBuffer(info, 0)
        while (index >= 0) {
            if (info.size > 0) {
                val out = codec.getOutputBuffer(index)
                if (out != null) {
                    val pcm = ByteArray(info.size)
                    out.position(info.offset)
                    out.get(pcm, 0, info.size)
                    track?.write(pcm, 0, pcm.size)
                    playedFrames++
                    activeCodec = "opus"
                }
            }
            codec.releaseOutputBuffer(index, false)
            index = codec.dequeueOutputBuffer(info, 0)
        }
    }

    private fun openDecoder(): MediaCodec? = try {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, CHANNELS
        ).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(opusHead()))
            setByteBuffer("csd-1", ByteBuffer.wrap(longLE(PRE_SKIP_NS)))
            setByteBuffer("csd-2", ByteBuffer.wrap(longLE(SEEK_PRE_ROLL_NS)))
        }
        MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS).apply {
            configure(format, null, null, 0)
            start()
            decoder = this
            presentationTimeUs = 0
            println("AUDIO: opened Opus decoder ${this.name}")
        }
    } catch (e: Exception) {
        println("AUDIO: no Opus decoder: $e")
        null
    }

    /** The 19-byte `OpusHead` identification header MediaCodec wants as csd-0. */
    private fun opusHead(): ByteArray = ByteBuffer.allocate(19)
        .order(ByteOrder.LITTLE_ENDIAN)
        .put("OpusHead".toByteArray(Charsets.US_ASCII))
        .put(1)                            // version
        .put(CHANNELS.toByte())
        .putShort(PRE_SKIP_SAMPLES.toShort())
        .putInt(SAMPLE_RATE)
        .putShort(0)                       // output gain
        .put(0)                            // channel mapping family
        .array()

    private fun longLE(value: Long): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array()

    private fun releaseDecoder() {
        try { decoder?.stop() } catch (_: Exception) {}
        try { decoder?.release() } catch (_: Exception) {}
        decoder = null
    }

    private fun releaseTrack() {
        try { track?.pause() } catch (_: Exception) {}
        try { track?.flush() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
        track = null
    }
}
