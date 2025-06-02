# tokencount

`tokencount` is a simple Python-based tool for counting the number of tokens in a given input using the `tiktoken` library.

## Usage

You can use `tokencount` by piping text input into the script. For example:

```bash
cat file.txt | ./tokencount.py
```

The tool will process the input and return the total number of tokens counted.

## Requirements

- Python 3.x
- `tiktoken` library

## Installation

To install the required dependencies, run:

```bash
pip install tiktoken
```

## How It Works

`tokencount` reads the input text from standard input, processes it using the `tiktoken` library, and outputs the total token count. This is useful for analyzing token usage in text data, especially for applications involving token-based models.

## Example

Input:

```text
This is an example text.
```

Command:

```bash
echo "This is an example text." | ./tokencount.py
```

Output:

```
6
```

## License

This tool is open-source and distributed under the MIT License.