class LanguagePair {
  const LanguagePair({
    required this.label,
    required this.sourceLanguage,
    required this.targetLanguage,
  });

  final String label;
  final String sourceLanguage;
  final String targetLanguage;
}

const languagePairs = [
  LanguagePair(
    label: 'Korean -> English',
    sourceLanguage: 'ko',
    targetLanguage: 'en',
  ),
  LanguagePair(
    label: 'English -> Korean',
    sourceLanguage: 'en',
    targetLanguage: 'ko',
  ),
  LanguagePair(
    label: 'Korean -> Japanese',
    sourceLanguage: 'ko',
    targetLanguage: 'ja',
  ),
  LanguagePair(
    label: 'Japanese -> Korean',
    sourceLanguage: 'ja',
    targetLanguage: 'ko',
  ),
  LanguagePair(
    label: 'Korean -> Chinese',
    sourceLanguage: 'ko',
    targetLanguage: 'zh',
  ),
  LanguagePair(
    label: 'Chinese -> Korean',
    sourceLanguage: 'zh',
    targetLanguage: 'ko',
  ),
  LanguagePair(
    label: 'Korean -> Vietnamese',
    sourceLanguage: 'ko',
    targetLanguage: 'vi',
  ),
  LanguagePair(
    label: 'Vietnamese -> Korean',
    sourceLanguage: 'vi',
    targetLanguage: 'ko',
  ),
];
