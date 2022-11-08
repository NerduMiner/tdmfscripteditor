import tdmfscript;
import std.file;
import std.path;
import std.stdio;

int main(string[] args)
{
	if (args.length == 1)
	{
		throw new Exception("No arguments given, please supply command and/or its arguments.");
	}
	switch(args[1]) 
	{
		case "extract":
			File script = File(args[2], "rb");
			extractScriptNew(script, 7);
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
			repackScriptNew(json, 7);
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
