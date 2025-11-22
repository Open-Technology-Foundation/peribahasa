# peribahasa

A command-line tool for displaying random Indonesian proverbs (peribahasa) with their meanings.

## Overview

`peribahasa` is a [BASH-CODING-STANDARD](https://github.com/Open-Technology-Foundation/bash-coding-standard)-compliant Bash script that retrieves and displays random Indonesian proverbs from a SQLite database. The tool intelligently tracks which proverbs have been displayed to ensure variety and automatically resets when all proverbs have been shown.

## Features

- **Random proverb selection** - Displays random Indonesian proverbs with their meanings
- **Smart tracking** - Keeps track of displayed proverbs to avoid repetition
- **Multiple output formats** - Supports both plain text and HTML output
- **Automatic reset** - Automatically resets usage tracking when all proverbs have been displayed
- **Length filtering** - Option to limit proverb length for specific use cases
- **File output** - Can output to files or stdout
- **Color-coded terminal output** - Enhanced readability with ANSI color codes

## Requirements

- Bash 5.2+
- sqlite3
- SQLite database: `peribahasa.db`

## Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd peribahasa
   ```

2. Ensure the script is executable:
   ```bash
   chmod +x peribahasa
   ```

3. Verify the database exists:
   ```bash
   ls -l peribahasa.db
   ```

## Usage

### Basic Usage

Display a random proverb in text format:
```bash
./peribahasa
```

### Options

```
-f, --format FORMAT    Output format: text|html (default: text)
-m, --maxlen LENGTH    Maximum combined length of proverb and meaning
-o, --output FILENAME  Output to file (default: /dev/stdout)
-v, --verbose          Enable verbose output
-q, --quiet            Suppress verbose output (default)
-V, --version          Display version information
-h, --help             Display help message
```

### Examples

Display proverb in HTML format:
```bash
./peribahasa -f html
```

Output to a file with verbose logging:
```bash
./peribahasa -v -o output.txt
```

Limit proverb length to 100 characters:
```bash
./peribahasa -m 100
```

Combined short options:
```bash
./peribahasa -vf html
```

## Output Formats

### Text Format (default)
```
Ada udang di balik batu
There is a hidden agenda or ulterior motive
```

### HTML Format
```html
<!-- peribahasa indonesia 2025-11-22 10:30 -->
<div class='peribahasa'>&ldquo;Ada udang di balik batu&rdquo;</div>
<div class='artinya'>There is a hidden agenda or ulterior motive</div>
```

## Database Schema

The tool uses a SQLite database (`peribahasa.db`) with the following structure:

- `id` - Unique identifier
- `peribahasa` - The Indonesian proverb
- `artinya` - The meaning/translation
- `dipakai` - Usage flag (0 = unused, 1 = used)

## How It Works

1. The script queries the database for unused proverbs (where `dipakai=0`)
2. If no unused proverbs exist, all are automatically reset to unused
3. A random proverb is selected from the unused pool
4. The proverb is displayed in the chosen format
5. The proverb is marked as used in the database

## Development

This project follows the [BASH-CODING-STANDARD](https://github.com/Open-Technology-Foundation/bash-coding-standard).

### Coding Principles
- K.I.S.S. (Keep It Simple, Stupid)
- "The best process is no process"
- "Everything should be made as simple as possible, but not any simpler"

### Style Guidelines
- 2-space indentation
- `set -euo pipefail` for error handling
- Descriptive variable names with `declare`/`local`
- Prefer `[[` over `[` for conditionals
- All scripts end with `#fin` marker

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

When contributing:
- Follow the [BASH-CODING-STANDARD](https://github.com/Open-Technology-Foundation/bash-coding-standard)
- Test thoroughly with various inputs
- Update documentation as needed
- Ensure shellcheck compliance

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE).

## Author

Gary Dean (Biksu Okusi)

---

**◉** Info | **▲** Warning | **✓** Success | **✗** Error
