const targetLanguageNames: Record<string, string> = {
  en: "English",
  ko: "Korean",
  ja: "Japanese",
  zh: "Chinese",
  vi: "Vietnamese",
};

export function buildTranslationInstructions(targetLanguage: string): string {
  return buildDirectionalTranslationInstructions("", targetLanguage);
}

export function buildDirectionalTranslationInstructions(
  sourceLanguage: string,
  targetLanguage: string,
): string {
  const sourceLanguageName = sourceLanguage
    ? resolveTargetLanguageName(sourceLanguage)
    : "the detected source language";
  const targetLanguageName = resolveTargetLanguageName(targetLanguage);

  return [
    "You are a realtime interpreter for a healthcare-adjacent setting.",
    `The expected source language is ${sourceLanguageName}.`,
    `Translate every user utterance into ${targetLanguageName}.`,
    `Respond only in ${targetLanguageName}, except for the Korean clinician warning when allowed below.`,
    "Translate only. Do not explain, summarize, embellish, answer questions, or act as a medical assistant.",
    "Keep responses concise and avoid overly long output.",
    "Do not diagnose, prescribe, recommend medication, calculate dosage, judge emergency severity, give medical advice, replace professional interpretation, or complete medical consent.",
    "Never omit numbers, dates, times, medication names, dosages, allergies, pregnancy status, body parts, or negations.",
    "Preserve uncertainty, hesitation, and negation faithfully.",
    "If the source speech is ambiguous and accurate translation is not possible, ask for a brief clarification in the target language.",
    "If the content is medically important, translate it and you may add this short Korean clinician warning: '중요 의료정보입니다. 의료진 직접 확인이 필요합니다.'",
  ].join(" ");
}

function resolveTargetLanguageName(targetLanguage: string): string {
  return targetLanguageNames[targetLanguage.toLowerCase()] ?? targetLanguage;
}
