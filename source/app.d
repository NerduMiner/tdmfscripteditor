import tdmfscript;
import tdmfscriptnew;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio;

int main(string[] args)
{
	if (args.length == 1)
	{
		writeln("extract-[version] where version goes from `v2` to `v6`, alternatively `old`");
		writeln("\textracts [version] files to json");
		writeln();
		writeln();
		writeln("repack-[version] where version goes from `v2` to `v6`, alternatively `old`");
		writeln("\trepacks [version] files from json to the binary format used in-game.");
		return 0;
	}
	switch(args[1]) 
	{
		case "-v":
		case "version":
			writeln("TDMF Script Editor - v1.0.10");
			return 0;
		case "-h":
		case "help":
			writeln("extract-[version] where version goes from `v2` to `v6`, alternatively `old`");
			writeln("\textracts [version] files to json");
			writeln();
			writeln();
			writeln("repack-[version] where version goes from `v2` to `v6`, alternatively `old`");
			writeln("\trepacks [version] files from json to the binary format used in-game.");
			return 0;
		case "extract":
			File script = File(args[2], "rb");
			// Figure out the version of this script with our config file
			File config = File("config.dpmf", "r"); // This is just a text file in disguise
			uint scriptVersion = 7;
			string line;
			while ((line = config.readln()) !is null)
			{
				string identifier = line.split[0];
				uint defVer = to!uint(line.split[1]);
				if (identifier == args[2].split(".")[0])
				{
					scriptVersion = defVer;
					break;
				}
			}
			extractScriptBetter(script, scriptVersion);
			return 0;
		case "extract-v2":
			File script = File(args[2], "rb");
			extractScriptNew(script, 2);
			return 0;
		case "extract-v3":
			File script = File(args[2], "rb");
			extractScriptNew(script, 3);
			return 0;
		case "extract-v4":
			File script = File(args[2], "rb");
			extractScriptNew(script, 4);
			return 0;
		case "extract-v5":
			File script = File(args[2], "rb");
			extractScriptNew(script, 5);
			return 0;
		case "extract-v6":
			File script = File(args[2], "rb");
			extractScriptNew(script, 6);
			return 0;
		case "extract-old":
			File script = File(args[2], "rb");
			extractScriptNew(script, 1);
			return 0;
		case "repack":
			File json = File(args[2], "r");
			// Figure out the version of this script with our config file
			File config = File("config.dpmf", "r"); // This is just a text file in disguise
			uint scriptVersion = DEFAULT_VERSION;
			string line;
			while ((line = config.readln()) !is null)
			{
				string identifier = line.split[0];
				uint defVer = to!uint(line.split[1]);
				if (identifier == args[2].split(".")[0])
				{
					scriptVersion = defVer;
					break;
				}
			}
			repackScriptBetter(json, scriptVersion);
			return 0;
		case "repack-v2":
			File json = File(args[2], "r");
			repackScriptNew(json, 2);
			return 0;
		case "repack-v3":
			File json = File(args[2], "r");
			repackScriptNew(json, 3);
			return 0;
		case "repack-v4":
			File json = File(args[2], "r");
			repackScriptNew(json, 4);
			return 0;
		case "repack-v5":
			File json = File(args[2], "r");
			repackScriptNew(json, 5);
			return 0;
		case "repack-v6":
			File json = File(args[2], "r");
			repackScriptNew(json, 6);
			return 0;
		case "repack-old":
			File json = File(args[2], "r");
			repackScriptNew(json, 1);
			return 0;
		default:
			return 1;
	}
}
