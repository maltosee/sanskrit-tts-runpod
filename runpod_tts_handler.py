import runpod
import os
import base64
import torch
import numpy as np
import time
from typing import List, Dict, Any, Optional

# Version for tracking deployments
HANDLER_VERSION = "v1.0-TTS-SANSKRIT-BATCH"
print(f"🚀 TTS HANDLER VERSION: {HANDLER_VERSION}")

# Voice configurations from BEAM
VOICE_CONFIGS = {
    "aryan_default": "Aryan speaks in a warm, respectful tone suitable for Sanskrit conversation while ensuring proper halant pronunciations and clear consonant clusters.",
    "aryan_scholarly": "Aryan recites Sanskrit with scholarly precision and poetic sensibility while ensuring proper halant pronunciations and clear consonant clusters.",
    "aryan_meditative": "Aryan speaks in a serene, meditative tone with slow, deliberate pacing while ensuring proper halant pronunciations and clear consonant clusters.",
    "priya_default": "Priya speaks in a warm, respectful tone suitable for Sanskrit conversation while ensuring proper halant pronunciations and clear consonant clusters, with a feminine voice quality."
}

# Global model cache
_synthesizer = None
_has_warmed = False
_model_loaded = False

def get_synthesizer(model_name: str = "ai4bharat/indic-parler-tts"):
    """
    Load Parler-TTS model with BEAM optimizations adapted for RunPod
    """
    global _synthesizer, _has_warmed, _model_loaded

    if _synthesizer is None:
        print("🔄 Loading TTS model...")
        start_time = time.time()

        try:
            from parler_tts import ParlerTTSForConditionalGeneration
            from transformers import AutoTokenizer

            # Device setup with BEAM's logic
            device = "cuda" if torch.cuda.is_available() else "cpu"
            torch_dtype = torch.float16 if device == "cuda" else torch.float32

            print(f"📱 Using device: {device} with dtype: {torch_dtype}")

            # Load model with BEAM's configuration
            model = ParlerTTSForConditionalGeneration.from_pretrained(
                model_name,
                torch_dtype=torch_dtype
            )

            if torch.cuda.is_available():
                model = model.to("cuda")
                # Enable cudnn benchmark for optimization (from BEAM)
                torch.backends.cudnn.benchmark = True
                print(f"🎯 GPU Memory allocated: {torch.cuda.memory_allocated() / 1024**3:.2f} GB")

            model.eval()
            torch.set_grad_enabled(False)

            # Load tokenizers with BEAM's padding configuration
            tokenizer = AutoTokenizer.from_pretrained(model_name)
            description_tokenizer = AutoTokenizer.from_pretrained(model.config.text_encoder._name_or_path)

            # Set padding side for consistent batching (BEAM optimization)
            tokenizer.padding_side = "left"
            description_tokenizer.padding_side = "left"

            _synthesizer = {
                'model': model,
                'tokenizer': tokenizer,
                'description_tokenizer': description_tokenizer,
                'sampling_rate': model.config.sampling_rate,
                'device': device,
                'torch_dtype': torch_dtype
            }

            load_time = time.time() - start_time
            print(f"✅ Model loaded successfully in {load_time:.2f}s")
            _model_loaded = True

        except Exception as e:
            print(f"❌ Error loading model: {e}")
            raise e

    # Warmup logic from BEAM
    if not _has_warmed and _model_loaded:
        try:
            print("🔥 Warming up model...")
            # Warmup with simple text (BEAM's approach)
            _synthesizer['description_tokenizer']("Test description", return_tensors="pt")
            _synthesizer['tokenizer']("हैलो", return_tensors="pt")
            # Clear cache after warmup
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            print("✅ Warmup completed")
            _has_warmed = True
        except Exception as e:
            print(f"⚠️ Warmup failed: {e}")

    return _synthesizer

def estimate_tokens_needed(text: str, tokens_per_word: int = 70) -> int:
    """
    Estimate tokens needed based on word count (from BEAM)
    """
    words = len(text.split())
    estimated_tokens = words * tokens_per_word
    return max(50, min(estimated_tokens, 2000))  # Clamp between 50-2000

def _enforce_batch_limits(text_chunks: list, max_chunks: int = 50):
    """Validate batch input limits (from BEAM)"""
    if not isinstance(text_chunks, list) or len(text_chunks) == 0:
        raise ValueError("text_chunks must be a non-empty list")
    if len(text_chunks) > max_chunks:
        raise ValueError(f"Batch size {len(text_chunks)} exceeds limit {max_chunks}")

    for i, chunk in enumerate(text_chunks):
        if not isinstance(chunk, str) or not chunk.strip():
            raise ValueError(f"Chunk {i} must be a non-empty string")
        if len(chunk) > 200:  # ~10 words * 20 chars avg
            raise ValueError(f"Chunk {i} length {len(chunk)} exceeds 200 characters")

def batch_generate_audio(model_name: str, text_chunks: list, voice_key: str = "aryan_default",
                        tokens_per_word: int = 70, do_sample: bool = True,
                        temperature: float = 1.0, max_chunks: int = 50):
    """
    Generate audio for batch of text chunks using BEAM's safe optimizations
    """
    _enforce_batch_limits(text_chunks, max_chunks)

    synthesizer = get_synthesizer(model_name)
    model = synthesizer['model']
    tokenizer = synthesizer['tokenizer']
    desc_tokenizer = synthesizer['description_tokenizer']
    device = synthesizer['device']
    torch_dtype = synthesizer['torch_dtype']

    voice_description = VOICE_CONFIGS.get(voice_key, VOICE_CONFIGS["aryan_default"])

    # Calculate max tokens needed for any chunk in batch (BEAM's approach)
    max_tokens = max([estimate_tokens_needed(chunk, tokens_per_word) for chunk in text_chunks])

    print(f"🎵 Processing {len(text_chunks)} chunks with max_tokens: {max_tokens}")

    # Batch tokenization - process all chunks at once (BEAM's Modal approach)
    text_tokens = tokenizer(text_chunks, return_tensors="pt", padding=True).to(device)
    desc_tokens = desc_tokenizer([voice_description] * len(text_chunks), return_tensors="pt", padding=True).to(device)

    t0 = time.time()

    # Single batch generation call with mixed precision (BEAM's approach)
    with torch.inference_mode():
        if device == "cuda":
            with torch.amp.autocast("cuda", dtype=torch_dtype):
                generation = model.generate(
                    input_ids=desc_tokens.input_ids,
                    attention_mask=desc_tokens.attention_mask,
                    prompt_input_ids=text_tokens.input_ids,
                    prompt_attention_mask=text_tokens.attention_mask,
                    return_dict_in_generate=True,
                    min_new_tokens=20,
                    max_new_tokens=max_tokens,
                    do_sample=do_sample,
                    temperature=temperature
                )
        else:
            generation = model.generate(
                input_ids=desc_tokens.input_ids,
                attention_mask=desc_tokens.attention_mask,
                prompt_input_ids=text_tokens.input_ids,
                prompt_attention_mask=text_tokens.attention_mask,
                return_dict_in_generate=True,
                min_new_tokens=30,
                max_new_tokens=max_tokens,
                do_sample=do_sample,
                temperature=temperature
            )

    if torch.cuda.is_available():
        torch.cuda.synchronize()  # Wait for GPU (BEAM's approach)
    t1 = time.time()

    # Extract individual audio buffers (BEAM's approach)
    audio_buffers = []
    for i in range(len(text_chunks)):
        audio = generation.sequences[i, :generation.audios_length[i]]
        audio_numpy = audio.to(torch.float32).cpu().numpy().squeeze()
        audio_buffers.append(audio_numpy.astype(np.float32))

    # Clear GPU cache after processing (BEAM's approach)
    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    processing_time = t1 - t0
    print(f"✅ Generated {len(audio_buffers)} audio chunks in {processing_time:.2f}s")

    return audio_buffers, synthesizer['sampling_rate'], processing_time

def handler(event):
    """
    RunPod serverless handler - simplified, no streaming
    """
    print(f"📨 TTS Handler {HANDLER_VERSION} received event: {event}")

    try:
        # Extract parameters with defaults (matching BEAM's interface)
        model_name = event.get("model_name", "ai4bharat/indic-parler-tts")
        text_chunks = event.get("text_chunks", [])
        voice = event.get("voice", "aryan_default")
        tokens_per_word = event.get("tokens_per_word", 70)
        do_sample = event.get("do_sample", True)
        temperature = event.get("temperature", 1.0)
        max_chunks = event.get("max_chunks", 20)

        # Validation
        if not text_chunks or len(text_chunks) == 0:
            return {"error": "text_chunks array required"}

        print(f"🎯 Processing {len(text_chunks)} chunks with voice: {voice}")

        # Generate audio using BEAM's batch function
        audio_buffers, sampling_rate, processing_time = batch_generate_audio(
            model_name, text_chunks, voice, tokens_per_word, do_sample, temperature, max_chunks
        )

        # Convert to base64 (matching BEAM's output format)
        response_data = {
            "audio_buffers": [base64.b64encode(buf.tobytes()).decode('utf-8') for buf in audio_buffers],
            "sampling_rate": sampling_rate,
            "buffer_count": len(audio_buffers),
            "processing_time_seconds": processing_time,
            "chunks_processed": len(text_chunks),
            "handler_version": HANDLER_VERSION
        }

        print(f"✅ Successfully processed {len(text_chunks)} chunks")
        return response_data

    except Exception as e:
        error_msg = str(e)
        print(f"❌ ERROR in TTS handler: {error_msg}")
        # Clean error handling without holding tensor references (BEAM's approach)
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        return {"error": error_msg, "handler_version": HANDLER_VERSION}

def test_handler():
    """
    Test function with Sanskrit text
    """
    test_event = {
        "text_chunks": [
            "ॐ गं गणपतये नमः",
            "आपूर्यमाणमचलप्रतिष्ठं समुद्रम्",
            "या निशा सर्वभूतानां तस्यां जागर्ति संयमी"
        ],
        "voice": "aryan_default",
        "model_name": "ai4bharat/indic-parler-tts"
    }

    print("🧪 Running test...")
    result = handler(test_event)

    if "error" not in result:
        print(f"✅ Test successful: {result['buffer_count']} audio buffers generated")
        print(f"   Sample rate: {result['sampling_rate']} Hz")
        print(f"   Processing time: {result['processing_time_seconds']:.2f}s")
    else:
        print(f"❌ Test failed: {result['error']}")

    return result

if __name__ == "__main__":
    print(f"🚀 Starting RunPod TTS Handler {HANDLER_VERSION}")

    # Test locally if not in RunPod environment
    if os.environ.get("RUNPOD_POD_ID") is None:
        print("🧪 Running in test mode...")
        test_handler()
    else:
        print("🌐 Starting RunPod serverless...")
        runpod.serverless.start({"handler": handler})