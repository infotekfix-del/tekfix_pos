/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./lib/**/*.{dart,html,js}",
    "./web/**/*.{html,js}",
    "./src/**/*.{html,js,ts,jsx,tsx}",
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        tek: {
          'bg-main': '#080D1C',
          'bg-secondary': '#10182B',
          'bg-card': '#151F38',
          'bg-card-hover': '#1E2A4B',
          'primary': '#7957FF',
          'primary-light': '#9074FF',
          'primary-dark': '#6038F6',
          'secondary': '#A78BFA',
          'secondary-soft': '#C4B5FD',
          'success': '#22C55E',
          'warning': '#FBBF24',
          'error': '#FB7185',
          'text-primary': '#F8FAFC',
          'text-secondary': '#A6B0C3',
          'text-muted': '#6B7A99',
          'border': '#293550',
          'border-subtle': '#1C263D',
        },
      },
      fontFamily: {
        sans: ['"Noto Sans Malayalam"', 'Inter', 'Segoe UI', 'Roboto', 'sans-serif'],
        malayalam: ['"Noto Sans Malayalam"', 'sans-serif'],
      },
      boxShadow: {
        'tek-card': '0 6px 16px rgba(0, 0, 0, 0.35)',
        'tek-glow': '0 4px 14px rgba(121, 87, 255, 0.35)',
        'tek-nav': '0 8px 24px rgba(0, 0, 0, 0.5)',
      },
    },
  },
  plugins: [],
};
