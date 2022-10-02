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
			extractScriptNew(script, 3);
			return 0;
		case "extract-v2":
			File script = File(args[2], "rb");
			extractScriptNew(script, 2);
			return 0;
		case "extract-old":
			File script = File(args[2], "rb");
			extractScriptNew(script, 1);
			return 0;
		case "repack":
			File json = File(args[2], "r");
			repackScriptNew(json, 3);
			return 0;
		case "repack-old":
			File json = File(args[2], "r");
			repackScriptNew(json, 1);
			return 0;
		default:
			return 1;
	}
}
