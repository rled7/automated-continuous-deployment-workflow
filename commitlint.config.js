export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [
      2,
      'always',
      ['app', 'infra', 'ci', 'docs', 'chore', 'test', 'sec'],
    ],
    'header-max-length': [2, 'always', 100],
  },
};
