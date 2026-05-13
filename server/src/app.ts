import { GoogleGenAI, type LiveConnectConfig } from "@google/genai";
import cors from "cors";
import dotenv from "dotenv";
import express from "express";
import { buildBidirectionalTranslationInstructions } from "./prompts.js";

dotenv.config();

const app = express();
const geminiApiKey = process.env.GEMINI_API_KEY;

const geminiLiveModel =
  process.env.GEMINI_LIVE_MODEL ??
  "gemini-2.5-flash-native-audio-preview-12-2025";
const geminiApiVersion = "v1alpha";
const geminiWebsocketBaseUrl =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained";

app.use(express.json({ limit: "16kb" }));

// TODO: Restrict CORS to trusted app origins before production release.
app.use(cors());

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

app.post("/session", async (req, res) => {
  if (!geminiApiKey) {
    res.status(500).json({ error: "GEMINI_API_KEY is not configured" });
    return;
  }

  const primaryLanguage = parseLanguage(req.body?.primaryLanguage, "ko");
  const secondaryLanguage = parseLanguage(req.body?.secondaryLanguage, "en");
  const instructions = buildBidirectionalTranslationInstructions(
    primaryLanguage,
    secondaryLanguage,
  );
  const liveConfig = buildGeminiLiveConfig(instructions);

  try {
    const ai = new GoogleGenAI({
      apiKey: geminiApiKey,
      apiVersion: geminiApiVersion,
    });
    const token = await ai.authTokens.create({
      config: {
        uses: 1,
        newSessionExpireTime: new Date(Date.now() + 60_000).toISOString(),
        expireTime: new Date(Date.now() + 30 * 60_000).toISOString(),
        liveConnectConstraints: {
          model: geminiLiveModel,
          config: liveConfig,
        },
        lockAdditionalFields: [
          "responseModalities",
          "systemInstruction",
          "inputAudioTranscription",
          "outputAudioTranscription",
          "realtimeInputConfig",
          "temperature",
        ],
      },
    });

    if (!token.name) {
      res.status(502).json({ error: "Gemini session token was empty" });
      return;
    }

    res.json({
      provider: "gemini",
      token: token.name,
      expiresAt: Math.floor((Date.now() + 30 * 60_000) / 1000),
      model: geminiLiveModel,
      primaryLanguage,
      secondaryLanguage,
      websocketUrl: `${geminiWebsocketBaseUrl}?access_token=${encodeURIComponent(
        token.name,
      )}`,
      setup: {
        setup: {
          model: `models/${geminiLiveModel}`,
          generationConfig: {
            responseModalities: ["AUDIO"],
            temperature: 0.2,
          },
          systemInstruction: {
            parts: [{ text: instructions }],
          },
          inputAudioTranscription: {},
          outputAudioTranscription: {},
          realtimeInputConfig: {
            automaticActivityDetection: {
              disabled: false,
              silenceDurationMs: 900,
            },
          },
        },
      },
    });
  } catch (error) {
    console.error("Gemini Live session creation error", {
      message: error instanceof Error ? error.message : "Unknown error",
    });

    res.status(500).json({ error: "Failed to create Gemini Live session" });
  }
});

export default app;

function buildGeminiLiveConfig(instructions: string): LiveConnectConfig {
  return {
    responseModalities: ["AUDIO"],
    temperature: 0.2,
    systemInstruction: {
      parts: [{ text: instructions }],
    },
    inputAudioTranscription: {},
    outputAudioTranscription: {},
    realtimeInputConfig: {
      automaticActivityDetection: {
        disabled: false,
        silenceDurationMs: 900,
      },
    },
  } as LiveConnectConfig;
}

function parseLanguage(value: unknown, fallback: string): string {
  if (typeof value !== "string") {
    return fallback;
  }

  const trimmed = value.trim().toLowerCase();

  if (!/^[a-z-]{2,32}$/.test(trimmed)) {
    return fallback;
  }

  return trimmed;
}
