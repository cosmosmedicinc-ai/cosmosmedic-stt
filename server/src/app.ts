import cors from "cors";
import dotenv from "dotenv";
import express from "express";
import { buildDirectionalTranslationInstructions } from "./prompts.js";

dotenv.config();

const app = express();
const openAiApiKey = process.env.OPENAI_API_KEY;

const realtimeModel = "gpt-realtime";
const realtimeClientSecretsUrl =
  "https://api.openai.com/v1/realtime/client_secrets";
const realtimeCallsUrl = "https://api.openai.com/v1/realtime/calls";

app.use(express.json({ limit: "16kb" }));

// TODO: Restrict CORS to trusted app origins before production release.
app.use(cors());

app.get("/health", (_req, res) => {
  res.json({ ok: true });
});

app.post("/session", async (req, res) => {
  if (!openAiApiKey) {
    res.status(500).json({ error: "OPENAI_API_KEY is not configured" });
    return;
  }

  const sourceLanguage = parseLanguage(req.body?.sourceLanguage, "ko");
  const targetLanguage = parseLanguage(req.body?.targetLanguage, "en");
  const instructions = buildDirectionalTranslationInstructions(
    sourceLanguage,
    targetLanguage,
  );

  try {
    const response = await fetch(realtimeClientSecretsUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAiApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        session: {
          type: "realtime",
          model: realtimeModel,
          instructions,
          audio: {
            input: {
              transcription: {
                model: "gpt-4o-transcribe",
                language: sourceLanguage,
              },
            },
            output: {
              voice: "marin",
            },
          },
        },
      }),
    });

    const data = (await response.json()) as OpenAiClientSecretResponse;

    if (!response.ok) {
      console.error("OpenAI Realtime session creation failed", {
        status: response.status,
        code: data.error?.code,
        message: data.error?.message,
        param: data.error?.param,
        type: data.error?.type,
      });

      res.status(response.status).json({
        error: "Failed to create realtime session",
        status: response.status,
        openai: {
          code: data.error?.code,
          message: data.error?.message,
          param: data.error?.param,
          type: data.error?.type,
        },
      });
      return;
    }

    res.json({
      value: findClientSecret(data),
      expiresAt: findExpiresAt(data),
      model: realtimeModel,
      sourceLanguage,
      targetLanguage,
      callsUrl: realtimeCallsUrl,
    });
  } catch (error) {
    console.error("Realtime session creation error", {
      message: error instanceof Error ? error.message : "Unknown error",
    });

    res.status(500).json({ error: "Failed to create realtime session" });
  }
});

export default app;

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

function findClientSecret(data: OpenAiClientSecretResponse): string | undefined {
  return (
    data.value ??
    data.client_secret?.value ??
    data.session?.client_secret?.value
  );
}

function findExpiresAt(data: OpenAiClientSecretResponse): number | undefined {
  return (
    data.expires_at ??
    data.client_secret?.expires_at ??
    data.session?.client_secret?.expires_at
  );
}

type OpenAiClientSecretResponse = {
  value?: string;
  expires_at?: number;
  client_secret?: {
    value?: string;
    expires_at?: number;
  };
  session?: {
    client_secret?: {
      value?: string;
      expires_at?: number;
    };
  };
  error?: {
    code?: string;
    message?: string;
    param?: string;
    type?: string;
  };
};
