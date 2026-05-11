class LanguagePair {
  const LanguagePair({
    required this.label,
    required this.primaryLanguage,
    required this.secondaryLanguage,
    required this.primaryLanguageName,
    required this.secondaryLanguageName,
  });

  final String label;
  final String primaryLanguage;
  final String secondaryLanguage;
  final String primaryLanguageName;
  final String secondaryLanguageName;
}

const languagePairs = [
  LanguagePair(
    label: 'Korean <-> English',
    primaryLanguage: 'ko',
    secondaryLanguage: 'en',
    primaryLanguageName: 'Korean',
    secondaryLanguageName: 'English',
  ),
  LanguagePair(
    label: 'Korean <-> Japanese',
    primaryLanguage: 'ko',
    secondaryLanguage: 'ja',
    primaryLanguageName: 'Korean',
    secondaryLanguageName: 'Japanese',
  ),
  LanguagePair(
    label: 'Korean <-> Chinese',
    primaryLanguage: 'ko',
    secondaryLanguage: 'zh',
    primaryLanguageName: 'Korean',
    secondaryLanguageName: 'Chinese',
  ),
  LanguagePair(
    label: 'Korean <-> Vietnamese',
    primaryLanguage: 'ko',
    secondaryLanguage: 'vi',
    primaryLanguageName: 'Korean',
    secondaryLanguageName: 'Vietnamese',
  ),
];
