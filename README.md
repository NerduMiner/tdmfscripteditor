# tdmfscripteditor
A tool that converts the script files in The Denpa Men FREE to JSON and back
<br/> Compatibility with all script files from TDMF is not 100%, as of 3/20/2022 there are still many aspects of the format that are not yet fully understood
# Usage
Run the executable in CLI/Terminal. The desired file/folder you wish to handle with the tool needs to be put in the arguments like so:
<br/>`tdmfscripteditor [extract/repack] [name of script file/json]`
<br/>The command `extract` when paired with a binary script file will create an equivalent JSON formatted file, allowing for free form editing of text entries
<br/>The command `repack` when paired with a compatible JSON file will create an equivalent Binary Script file, allowing for use in TDMF mods
# JSON Formatting
There are three main parts to an outputted JSON file:
- "header": Contains information from the script file's header. Refrain from editing any values in this section, value names are also tenative and can change in the future
- "text_info": Contains an array of Text Entries, text is encoded in the Unicode format, ascii variables are denoted with brackets(`{}`) and other data is encapsulated in carats(`<>`), formatting of text entries is subject to change as the format is better understood in the future. Refrain from editing the flags portion of each text entry.
- "attributes": Contains a list of what is believed to be Script Attributes, refrain from editing this portion.
# Building
tdmfscripteditor requires a D compiler(DMD is recommended), downloads can be found at https://dlang.org/.<br/>Once installed, run `dub build` in your CLI/Terminal in the root directory of the repository to compile the project.
# Contributing
I have not yet established a consistent code style for this project. Keep this in mind if you decide to submit a pull request with features. I aim to keep with the D style, however https://dlang.org/dstyle.html
<br/>If you are submitting an issue, please provide as much relevant information as possible(what file you were working with, what archive from TDMF, relevant steps to reproduce, relevant system information, etc.).
# Credits
<br/>Thanks to Robert Pasiński for the pack-d binary i/o library https://code.dlang.org/packages/pack-d
