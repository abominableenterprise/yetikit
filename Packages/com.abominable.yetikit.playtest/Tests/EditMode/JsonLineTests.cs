using System.Text;
using NUnit.Framework;
using UnityEngine;

namespace YetiKit.Playtest.Tests
{
    public class JsonLineTests
    {
        static string Num(double value, int decimals) => JsonLine.Num(new StringBuilder(), value, decimals).ToString();

        [TestCase(1.23456, 3, "1.235")]
        [TestCase(1.5, 3, "1.5")]
        [TestCase(2.0, 3, "2")]
        [TestCase(-0.0004, 3, "0")]
        [TestCase(-0.0006, 3, "-0.001")]
        [TestCase(0.70710678, 4, "0.7071")]
        [TestCase(-0.99995, 4, "-1")]
        [TestCase(12.345, 2, "12.35")]
        [TestCase(1234.5, 0, "1235")]
        [TestCase(0.05, 3, "0.05")]
        [TestCase(-3.0001, 3, "-3")]
        public void RoundsAndTrims(double value, int decimals, string expected) => Assert.AreEqual(expected, Num(value, decimals));

        [Test]
        public void NaNAndInfinityAreNull()
        {
            Assert.AreEqual("null", Num(double.NaN, 3));
            Assert.AreEqual("null", Num(double.PositiveInfinity, 2));
        }

        [Test]
        public void StringsAreEscaped()
        {
            var text = JsonLine.Str(new StringBuilder(), "a\"b\\c\nd\u0001").ToString();
            Assert.AreEqual("\"a\\\"b\\\\c\\nd\\u0001\"", text);
            Assert.AreEqual("null", JsonLine.Str(new StringBuilder(), null).ToString());
        }

        [Test]
        public void LineHasTimeKindAndFields()
        {
            var sb = JsonLine.Begin(new StringBuilder(), 12.34567, "test_event");
            JsonLine.Field(sb, "id", 7);
            JsonLine.Field(sb, "side", "R");
            JsonLine.Field(sb, "ok", true);
            JsonLine.End(sb);
            Assert.AreEqual("{\"t\":12.346,\"k\":\"test_event\",\"id\":7,\"side\":\"R\",\"ok\":true}\n", sb.ToString());
        }

        [Test]
        public void MinimumInt64IsEmittedAsAJsonNumberByIntAndField()
        {
            Assert.AreEqual("-9223372036854775808", JsonLine.Int(new StringBuilder(), long.MinValue).ToString());
            var sb = JsonLine.Begin(new StringBuilder(), 0, "test");
            JsonLine.Field(sb, "min", long.MinValue);
            JsonLine.End(sb);
            Assert.AreEqual("{\"t\":0,\"k\":\"test\",\"min\":-9223372036854775808}\n", sb.ToString());
        }

        [TestCase("{\"t\":123}")]
        [TestCase("{\"other\":[{\"t\":2}],\"k\":\"other\"}")]
        [TestCase("{\"\\u0074\":123}")]
        [TestCase("{\"\\u006B\":\"other\"}")]
        public void ReservedTopLevelPayloadKeysAreKeptUnderData(string payload)
        {
            double time = 0;
            var log = new FlightLog(() => time);
            time = 1.25;
            Assert.AreEqual(AppendResult.Appended, log.AppendEvent("test_event", payload));
            Assert.AreEqual("{\"t\":1.25,\"k\":\"test_event\",\"d\":" + payload + "}\n", log.Buffer.ToString());
            Assert.AreEqual(1, log.Count("test_event"));
            Assert.AreEqual(0, log.Count("other"));
        }

        [Test]
        public void PoseRoundsPositionsToMillimetresAndQuaternionsToFourDecimals()
        {
            var sb = JsonLine.Pose7(new StringBuilder(), new Vector3(1.00049f, -0.0126f, 2f), new Quaternion(0.123456f, 0f, -0.5f, 0.86603f));
            Assert.AreEqual("[1,-0.013,2,0.1235,0,-0.5,0.866]", sb.ToString());
        }

        [Test]
        public void AppendEventMergesObjectFieldsAndWrapsOtherValues()
        {
            var log = new FlightLog(() => 0);
            log.AppendEvent("test_object", "{\"value\":{\"t\":123},\"quote\":\"\\\"k\\\":\"}");
            log.AppendEvent("test_text", "hello");
            log.AppendEvent("test_number", "42");
            log.AppendEvent("test_empty", null);
            Assert.AreEqual("{\"t\":0,\"k\":\"test_object\",\"value\":{\"t\":123},\"quote\":\"\\\"k\\\":\"}\n{\"t\":0,\"k\":\"test_text\",\"d\":\"hello\"}\n" +
                "{\"t\":0,\"k\":\"test_number\",\"d\":42}\n{\"t\":0,\"k\":\"test_empty\"}\n", log.Buffer.ToString());
            Assert.AreEqual(4, log.Events);
            Assert.AreEqual(1, log.Count("test_object"));
        }
    }
}
