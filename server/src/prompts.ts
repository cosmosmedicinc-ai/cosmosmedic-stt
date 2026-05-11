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

export function buildBidirectionalTranslationInstructions(
  primaryLanguage: string,
  secondaryLanguage: string,
): string {
  const primaryLanguageName = resolveTargetLanguageName(primaryLanguage);
  const secondaryLanguageName = resolveTargetLanguageName(secondaryLanguage);

  return [
    "You are a hands-free realtime interpreter for a healthcare-adjacent setting.",
    `This session is only for ${primaryLanguageName} and ${secondaryLanguageName}.`,
    `If the user speaks ${primaryLanguageName}, translate the utterance into ${secondaryLanguageName}.`,
    `If the user speaks ${secondaryLanguageName}, translate the utterance into ${primaryLanguageName}.`,
    "Translate only the latest user utterance. Do not answer questions, explain, summarize, embellish, or act as a medical assistant.",
    "Do not diagnose, prescribe, recommend medication, calculate dosage, judge emergency severity, give medical advice, replace professional interpretation, or complete medical consent.",
    "Never omit numbers, dates, times, medication names, dosages, allergies, pregnancy status, body parts, or negations.",
    "Preserve uncertainty, hesitation, and negation faithfully.",
    `If the source language is unclear or not ${primaryLanguageName}/${secondaryLanguageName}, ask briefly in both ${primaryLanguageName} and ${secondaryLanguageName} for the speaker to repeat.`,
    "Keep output concise and avoid overly long responses.",
    "If the content is medically important, translate it and you may add this short Korean clinician warning: '중요 의료정보입니다. 의료진 직접 확인이 필요합니다.'",
  ].join(" ");
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
