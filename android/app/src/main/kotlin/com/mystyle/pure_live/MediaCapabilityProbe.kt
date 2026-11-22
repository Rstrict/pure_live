package com.mystyle.purelive

import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

/**
 * What this device can actually decode in hardware.
 *
 * The player used to guess from core count alone, which cannot tell a device that
 * decodes 1080p60 in hardware from one that falls back to software and drops
 * frames. Android can answer directly: [MediaCodecList] enumerates every encoder
 * and decoder the platform exposes, including whether an entry is hardware-backed
 * and which profile/level each one accepts.
 *
 * The result is cached per process: the platform's decoder table is fixed for the
 * lifetime of the device, and enumerating it costs a few milliseconds that should
 * not be paid once per room.
 */
object MediaCapabilityProbe {

    private val cache = HashMap<String, Any>()

    @Synchronized
    fun describe(width: Int, height: Int, frameRate: Int): Map<String, Any> {
        val key = "$width:$height:$frameRate"
        cache[key]?.let { return it as Map<String, Any> }

        val avc = findDecoder(MediaFormat.MIMETYPE_VIDEO_AVC, width, height, frameRate)
        val hevc = findDecoder(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height, frameRate)

        val result = mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "hardware" to Build.HARDWARE,
            "avc" to avc,
            "hevc" to hevc,
            // A device with neither codec in hardware cannot sustain a high-bitrate
            // live stream in software on this class of hardware.
            "softwareOnly" to (avc["hardware"] != true && hevc["hardware"] != true),
        )
        cache[key] = result
        return result
    }

    private fun findDecoder(
        mime: String,
        width: Int,
        height: Int,
        frameRate: Int,
    ): Map<String, Any> {
        var hardware = false
        var supportsSize = false
        var supports60 = false
        val decoderNames = ArrayList<String>()

        try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            for (info in list.codecInfos) {
                if (info.isEncoder) continue
                if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue

                val isHardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.isHardwareAccelerated
                } else {
                    // Before Q there is no hardware flag: vendor decoders are the
                    // names that do not start with the software prefixes.
                    !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")
                }
                if (!isHardware) continue

                var sizeOk = false
                var rateOk = false
                try {
                    val caps = info.getCapabilitiesForType(mime)
                    // A decoder that advertises the mime but cannot describe its video
                    // limits is not trusted for this size.
                    val video = caps.videoCapabilities
                    if (video != null) {
                        sizeOk = video.isSizeSupported(width, height)
                        // `getSupportedFrameRatesFor` returns a closed range of
                        // accepted rates for this size, so the target rate is a
                        // membership test rather than a comparison against a list.
                        val rates = video.getSupportedFrameRatesFor(width, height)
                        rateOk = rates != null && rates.contains(frameRate.toDouble())
                    }
                } catch (_: Throwable) {
                    // Treat an unreadable capability record as "not for this size".
                    sizeOk = false
                    rateOk = false
                }
                if (!sizeOk) continue
                hardware = true
                supportsSize = true
                if (rateOk) supports60 = true
                decoderNames.add(info.name)
            }
        } catch (_: Throwable) {
            // An unreadable codec list is reported as "no hardware decoder".
        }

        return mapOf(
            "mime" to mime,
            "hardware" to hardware,
            "supportsSize" to supportsSize,
            // Frame-rate support matters for 高帧率 rooms: a decoder that manages
            // 1080p at 30 fps will drop frames on a 60 fps stream.
            "supportsFrameRate" to supports60,
            "decoders" to decoderNames.take(3),
        )
    }
}
